#!/usr/bin/env python3
"""The mobile composer opens quick keys on demand and makes Send press Enter."""
from __future__ import annotations

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


ROOT = Path(__file__).parents[1] / "Resources" / "mobile"
PANE = {
    "surface_id": "pane-1", "kind": "pane", "chat_capable": False,
    "agent_cli": "shell", "title": "Shell", "cwd": "/work", "keys": "safe",
}
AGENT = {
    "surface_id": "agent-1", "kind": "agent", "chat_capable": True,
    "team_name": "team", "agent_name": "worker", "agent_cli": "codex",
    "title": "Worker", "cwd": "/work", "keys": "safe",
}
POSTS: list[tuple[str, dict]] = []
POSTS_LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in {"/", "/index.html"}:
            return self.file("index.html", "text/html; charset=utf-8")
        if path == "/app.js":
            return self.file("app.js", "application/javascript; charset=utf-8")
        if path == "/app.css":
            return self.file("app.css", "text/css; charset=utf-8")
        if path == "/api/targets":
            return self.json({"targets": [PANE, AGENT]})
        if path.endswith("/screen"):
            return self.json({"surface_id": "pane-1", "format": "text", "text": "TERMINAL_MARKER"})
        if path.endswith("/transcript"):
            return self.json({"running": False, "in_flight": False, "entries": []})
        if path.endswith("/requests"):
            return self.json({"requests": []})
        self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        path = self.path.split("?", 1)[0]
        with POSTS_LOCK:
            POSTS.append((path, body))
        if path.endswith("/text"):
            return self.json({
                "surface_id": "pane-1", "kind": "pane", "mode": body.get("mode"),
                "delivered": True, "deduplicated": False, "request_id": body.get("request_id"),
            })
        if path.endswith("/key"):
            return self.json({"key": body.get("key"), "delivered": True})
        self.send_error(404)

    def file(self, name: str, content_type: str):
        data = (ROOT / name).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def json(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def value(payload):
    return payload.get("value") if isinstance(payload, dict) else payload


def wait(c: termmesh, surface: str, script: str, expected, label: str):
    deadline = time.monotonic() + 10
    last = None
    while time.monotonic() < deadline:
        last = value(c._call("browser.eval", {"surface_id": surface, "script": script}) or {})
        if last == expected:
            return
        time.sleep(0.1)
    raise termmeshError(f"{label}: expected {expected!r}, got {last!r}")


def wait_for_post(route: str, label: str) -> dict:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        with POSTS_LOCK:
            for path, body in POSTS:
                if path.endswith(route):
                    POSTS.remove((path, body))
                    return body
        time.sleep(0.1)
    raise termmeshError(f"{label}: no POST to {route}")


KEYS_STATE = (
    "(() => { const t = document.querySelector('#keys-toggle'), k = document.querySelector('#keys');"
    " return [t.hidden, k.hidden, t.getAttribute('aria-expanded')].join(':'); })()"
)


def main() -> int:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    browser = None
    try:
        with termmesh() as c:
            browser = c.open_browser(f"http://127.0.0.1:{server.server_port}/")
            wait(c, browser, "document.querySelector('#screen') ? document.querySelector('#screen').innerText : ''",
                 "TERMINAL_MARKER", "pane screen")
            wait(c, browser, KEYS_STATE, "false:true:false", "quick keys start closed behind the toggle")
            c._call("browser.click", {"surface_id": browser, "selector": "#keys-toggle"})
            wait(c, browser, KEYS_STATE, "false:false:true", "toggle opens the key row")
            c._call("browser.click", {"surface_id": browser, "selector": "#keys-toggle"})
            wait(c, browser, KEYS_STATE, "false:true:false", "toggle closes the key row")

            c._call("browser.eval", {
                "surface_id": browser,
                "script": "document.querySelector('#text').value = 'echo hi'; document.querySelector('#send').click(); 'ok'",
            })
            sent = wait_for_post("/text", "Send with text")
            if sent.get("submit") is not True or sent.get("mode") != "terminal" or sent.get("text") != "echo hi":
                raise termmeshError(f"terminal Send must submit text and Enter in one request: {sent}")

            wait(c, browser, "document.querySelector('#send').disabled", False, "Send re-enabled")
            c._call("browser.eval", {
                "surface_id": browser,
                "script": "document.querySelector('#text').value = ''; document.querySelector('#send').click(); 'ok'",
            })
            key = wait_for_post("/key", "Send with empty input")
            if key != {"key": "Enter"}:
                raise termmeshError(f"empty Send must press Enter only: {key}")

            c._call("browser.eval", {
                "surface_id": browser,
                "script": "const s = document.querySelector('#target'); s.value = 'agent-1'; s.dispatchEvent(new Event('change')); 'ok'",
            })
            wait(c, browser, "document.querySelector('#keys-toggle').hidden", True, "no key toggle for a native agent")

            c.close_surface(browser)
            browser = None
    finally:
        if browser is not None:
            try:
                with termmesh() as c:
                    c.close_surface(browser)
            except termmeshError:
                pass
        server.shutdown()
        server.server_close()
    print("PASS: mobile composer opens quick keys on demand and Send presses Enter")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
