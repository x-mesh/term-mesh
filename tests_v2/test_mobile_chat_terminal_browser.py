#!/usr/bin/env python3
"""The in-app browser keeps mobile Chat and Terminal content across view switches."""
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
TARGET = {
    "surface_id": "agent-1", "kind": "agent", "chat_capable": True,
    "team_name": "team", "agent_name": "worker", "agent_cli": "codex",
    "title": "Worker", "cwd": "/work", "keys": "safe",
}


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
            return self.json({"targets": [TARGET]})
        if path.endswith("/screen"):
            return self.json({"surface_id": "agent-1", "format": "text", "text": "TERMINAL_MARKER"})
        if path.endswith("/transcript"):
            return self.json({
                "running": True, "in_flight": False,
                "entries": [
                    {"id": "c1", "kind": "said", "speaker": "person", "text": "CHAT_MARKER"},
                    {"id": "c2", "kind": "answered", "text": "ANSWER_MARKER"},
                ],
            })
        if path.endswith("/requests"):
            return self.json({"requests": []})
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


def wait(c: termmesh, surface: str, script: str, expected: str, label: str):
    deadline = time.monotonic() + 10
    last = None
    while time.monotonic() < deadline:
        last = value(c._call("browser.eval", {"surface_id": surface, "script": script}) or {})
        if last == expected:
            return
        time.sleep(0.1)
    raise termmeshError(f"{label}: expected {expected!r}, got {last!r}")


def main() -> int:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    browser = None
    try:
        with termmesh() as c:
            browser = c.open_browser(f"http://127.0.0.1:{server.server_port}/")
            wait(c, browser, "!!document.querySelector('#chat-list') && document.querySelector('#chat-list').innerText.includes('CHAT_MARKER')", True, "Chat content")
            c._call("browser.click", {"surface_id": browser, "selector": "#view-terminal"})
            wait(c, browser, "document.querySelector('#screen') ? document.querySelector('#screen').innerText : ''", "TERMINAL_MARKER", "Terminal content")
            c._call("browser.click", {"surface_id": browser, "selector": "#view-chat"})
            wait(c, browser, "!!document.querySelector('#chat-list') && document.querySelector('#chat-list').innerText.includes('CHAT_MARKER')", True, "Chat content after switch")
            preserved = value(c._call("browser.eval", {
                "surface_id": browser,
                "script": "document.querySelector('#screen') ? document.querySelector('#screen').innerText : ''",
            }) or {})
            if preserved != "TERMINAL_MARKER":
                raise termmeshError(f"Terminal content was discarded after Chat switch: {preserved!r}")
            shot = c._call("browser.screenshot", {"surface_id": browser}) or {}
            if len(str(shot.get("png_base64") or "")) < 100:
                raise termmeshError("in-app browser screenshot is empty")
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
    print("PASS: in-app browser preserves mobile Chat and Terminal content across switches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
