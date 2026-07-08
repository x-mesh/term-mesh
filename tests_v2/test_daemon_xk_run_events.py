#!/usr/bin/env python3
"""xk_run event bus contract (T4, docs/xk-panel-phase2.md / XK-EVENTS-v1).

Verifies against a live term-meshd: (1) a subscriber that explicitly opts in
with kinds:["xk_run"] receives a published xk_run event in <1s, (2) a
default-filter subscriber never sees it, (3) an oversized event is rejected,
(4) an oversized tail is truncated server-side to 512 bytes.
"""
import json
import os
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmeshError, daemon_call, _default_daemon_socket_path


class EventSubscriber:
    """Raw streaming events.subscribe connection (daemon holds it open)."""

    def __init__(self, sock_path: str, kinds=None):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5.0)
        self.sock.connect(sock_path)
        self.buf = b""
        params = {"kinds": kinds} if kinds is not None else {}
        req = json.dumps({"id": 1, "method": "events.subscribe", "params": params}) + "\n"
        self.sock.sendall(req.encode("utf-8"))
        ack = self._read_frame(5.0)
        if not ack or (ack.get("result") or {}).get("status") != "subscribed":
            raise termmeshError(f"subscribe ack missing, got: {ack}")

    def _read_frame(self, timeout: float):
        deadline = time.time() + timeout
        while b"\n" not in self.buf:
            remaining = deadline - time.time()
            if remaining <= 0:
                return None
            self.sock.settimeout(remaining)
            try:
                chunk = self.sock.recv(8192)
            except socket.timeout:
                return None
            if not chunk:
                return None
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        try:
            return json.loads(line.decode("utf-8", errors="replace"))
        except json.JSONDecodeError:
            return None

    def wait_for_kind(self, kind: str, timeout: float):
        """Return the first frame of `kind` within timeout, else None (keepalives skipped)."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            frame = self._read_frame(max(0.05, deadline - time.time()))
            if frame and frame.get("kind") == kind:
                return frame
        return None

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def xk_event(**over):
    ev = {
        "kind": "xk_run", "v": 1, "source": "x-panel",
        "run": f"e2e-{int(time.time() * 1000)}", "run_kind": "review",
        "phase": "round1", "model": "claude", "state": "running",
        "elapsed_ms": 10, "title": "e2e target",
    }
    ev.update(over)
    return ev


def main() -> int:
    sock_path = _default_daemon_socket_path()
    if not os.path.exists(sock_path):
        print(f"SKIP: no term-meshd socket at {sock_path}")
        return 0

    opt_in = EventSubscriber(sock_path, kinds=["xk_run"])
    default_sub = EventSubscriber(sock_path)  # default filter set — must never see xk_run
    try:
        # 1) opt-in subscriber receives the event, fast
        ev = xk_event()
        t0 = time.time()
        daemon_call("events.publish", ev, daemon_socket=sock_path)
        got = opt_in.wait_for_kind("xk_run", 2.0)
        latency = time.time() - t0
        if not got:
            raise termmeshError("opt-in subscriber never received the xk_run event")
        if got.get("run") != ev["run"] or got.get("model") != "claude":
            raise termmeshError(f"delivered event mismatch: {got}")
        if latency >= 1.0:
            raise termmeshError(f"delivery took {latency:.2f}s (expected <1s)")

        # 2) default-filter subscriber saw nothing for that publish
        leaked = default_sub.wait_for_kind("xk_run", 0.7)
        if leaked:
            raise termmeshError(f"default subscriber must not receive xk_run, got: {leaked}")

        # 3) oversized event (>4 KiB) is rejected
        try:
            daemon_call("events.publish", xk_event(title="x" * 5000), daemon_socket=sock_path)
            raise termmeshError("oversized xk_run event was accepted (expected rejection)")
        except termmeshError as e:
            if "exceeds" not in str(e):
                raise

        # 4) tail is truncated server-side to <=512 bytes
        ev2 = xk_event(tail="y" * 600)
        daemon_call("events.publish", ev2, daemon_socket=sock_path)
        got2 = opt_in.wait_for_kind("xk_run", 2.0)
        if not got2:
            raise termmeshError("tail-truncation event never delivered")
        tail = got2.get("tail") or ""
        if len(tail.encode("utf-8")) > 512:
            raise termmeshError(f"tail not truncated: {len(tail)} chars")
    finally:
        opt_in.close()
        default_sub.close()

    print("PASS: xk_run bus — opt-in delivery <1s, default filter excluded, size caps enforced")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
