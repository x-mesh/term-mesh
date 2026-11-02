#!/usr/bin/env python3
"""Mobile Chat reaches the source GUI host through a relay pane."""
from __future__ import annotations

import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


MOBILE_ADDR = os.environ.get("TERMMESH_E2E_MOBILE_ADDR", "")
APP_SOCKET = os.environ.get("TERMMESH_SOCKET_PATH", "")
DAEMON_SOCKET = os.environ.get("TERMMESH_DAEMON_UNIX_PATH", "")


def wait_for(predicate, timeout_s: float, label: str):
    deadline = time.monotonic() + timeout_s
    last = None
    while time.monotonic() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(0.2)
    raise termmeshError(f"timed out waiting for {label}: {last!r}")


def daemon_rpc(method: str, params: dict) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(15)
        client.connect(DAEMON_SOCKET)
        client.sendall((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode())
        response = b""
        while not response.endswith(b"\n"):
            chunk = client.recv(65536)
            if not chunk:
                break
            response += chunk
    payload = json.loads(response)
    if payload.get("error"):
        raise termmeshError(f"{method} failed: {payload['error']}")
    return payload.get("result") or {}


def get(path: str) -> tuple[int, dict]:
    request = urllib.request.Request(f"http://{MOBILE_ADDR}{path}")
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())


def main() -> int:
    if not MOBILE_ADDR or not APP_SOCKET or not DAEMON_SOCKET:
        raise termmeshError("run through scripts/run-tests-v2.sh")
    with termmesh() as client:
        source = client.new_surface(panel_type="terminal")
        client.focus_surface(source)
        wait_for(lambda: client.read_terminal_text(source).strip(), 15, "source shell")
        started = client.peer_open_remote_pane()
        if not started.get("started"):
            raise termmeshError(f"remote pane did not start: {started!r}")

        def opened():
            result = client.peer_pane_status().get("last_open_result")
            return result if isinstance(result, dict) else None

        result = wait_for(opened, 60, "relay pane")
        if not result.get("ok"):
            raise termmeshError(f"relay pane failed: {result!r}")
        relay = str(result.get("panel_id") or "")
        if not relay:
            raise termmeshError(f"relay pane has no panel id: {result!r}")
        wait_for(lambda: client.read_terminal_text(relay).strip(), 20, "relay terminal output")

        daemon_rpc("remote.on", {
            "surface_id": relay,
            "kind": "pane",
            "app_socket": APP_SOCKET,
            "chat_capable": True,
            "remote_pane": True,
            "relay_host": "self-relay-e2e",
            "keys": "safe",
        })
        try:
            targets_status, targets = get("/api/targets")
            target = next((item for item in targets.get("targets", []) if item.get("surface_id") == relay), None)
            if targets_status != 200 or not target or target.get("relay_host") != "self-relay-e2e":
                raise termmeshError(f"relay target was not registered: {targets_status} {targets!r}")

            status, payload = get(f"/api/targets/{relay}/transcript?limit=1")
            text = json.dumps(payload)
            if "method_not_allowed" in text:
                raise termmeshError(f"Swift GUI host still rejects relay transcript RPC: {status} {payload!r}")
            if "session_unavailable" not in text:
                raise termmeshError(f"relay transcript did not reach the source daemon: {status} {payload!r}")
        finally:
            daemon_rpc("remote.off", {"surface_id": relay})
            client.close_surface(relay)
            client.close_surface(source)
    print("PASS: mobile relay Chat reaches the source daemon beyond the Swift allowlist")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
