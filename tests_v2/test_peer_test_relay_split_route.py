#!/usr/bin/env python3
"""Test Relay fails closed when configured is dead but discovered is live.

This is the production socket split-brain regression: a profile pins one
endpoint, discovery finds another, and the alternate must be reported as
reachable without silently turning the failed configured route green.
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


HOST_ENV = "TERMMESH_E2E_SPLIT_ROUTE_HOST"
DISCOVERED_ENV = "TERMMESH_E2E_SPLIT_ROUTE_DISCOVERED_SOCKET"
REQUIRE_ENV = "TERMMESH_E2E_REQUIRE_SPLIT_ROUTE"


class RemoteDroppingUnixListener:
    """Own an isolated remote socket that closes before peer Hello."""

    PROGRAM = r"""
import os, socket, sys
path, count_path = sys.argv[1:3]
for item in (path, count_path):
    try: os.unlink(item)
    except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(8)
open(count_path, 'w').write('0')
print('READY ' + str(os.getpid()), flush=True)
count = 0
while True:
    client, _ = s.accept()
    count += 1
    open(count_path, 'w').write(str(count))
    client.close()
"""

    def __init__(self, host: str) -> None:
        self.host = host
        token = uuid.uuid4().hex[:12]
        self.path = f"/tmp/tm-split-route-{token}.sock"
        self.count_path = f"/tmp/tm-split-route-{token}.count"
        self.process = None
        self.remote_pid = None

    def __enter__(self):
        self.process = subprocess.Popen(
            ["ssh", self.host, "python3", "-u", "-",
             self.path, self.count_path],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
        )
        self.process.stdin.write(self.PROGRAM)
        self.process.stdin.close()
        ready = self.process.stdout.readline().strip()
        fields = ready.split()
        if len(fields) != 2 or fields[0] != "READY" or not fields[1].isdigit():
            error = self.process.stderr.read()
            raise termmeshError(f"remote dead listener failed: {ready!r} {error!r}")
        self.remote_pid = int(fields[1])
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.remote_pid is not None:
            subprocess.run(
                ["ssh", self.host, "kill", str(self.remote_pid)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10,
            )
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        subprocess.run(
            ["ssh", self.host, "rm", "-f", self.path, self.count_path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10,
        )
        if self.remote_pid is not None:
            check = subprocess.run(
                ["ssh", self.host, "kill", "-0", str(self.remote_pid)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10,
            )
            if check.returncode == 0:
                raise termmeshError(
                    f"remote dead listener pid {self.remote_pid} survived cleanup"
                )

    def accepted_count(self) -> int:
        result = subprocess.run(
            ["ssh", self.host, "cat", self.count_path],
            capture_output=True, text=True, timeout=10,
        )
        try:
            return int(result.stdout.strip())
        except ValueError:
            return 0


def wait_for_probe(c: termmesh, operation_id: str, timeout_s: float = 45.0) -> dict:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        status = c.peer_route_probe_status(operation_id)
        if status.get("state") != "running":
            return status
        time.sleep(0.2)
    raise termmeshError(f"split-route probe timed out: {operation_id}")


def main() -> int:
    host = os.environ.get(HOST_ENV, "").strip()
    discovered = os.environ.get(DISCOVERED_ENV, "").strip()
    if not host or not discovered:
        if os.environ.get(REQUIRE_ENV) == "1":
            raise termmeshError(
                f"required split-route topology missing: set {HOST_ENV} and {DISCOVERED_ENV}"
            )
        print(f"SKIP: set {HOST_ENV} and {DISCOVERED_ENV}")
        return 0

    with RemoteDroppingUnixListener(host) as dead, termmesh() as c:
        started = c.peer_route_probe(host, dead.path, discovered)
        operation_id = started.get("operation_id")
        if not operation_id:
            raise termmeshError(f"route probe returned no operation id: {started!r}")
        status = wait_for_probe(c, operation_id)

        expected = {
            "state": "failed",
            "configured_socket": dead.path,
            "discovered_socket": discovered,
            "discovered_verified": True,
            "connected_socket": dead.path,
            "connected_verified": False,
            "route_verified": False,
        }
        mismatches = {
            key: {"expected": value, "actual": status.get(key)}
            for key, value in expected.items()
            if status.get(key) != value
        }
        if mismatches:
            raise termmeshError(
                f"split-route Test Relay verdict mismatch: {mismatches!r}; status={status!r}"
            )
        if dead.accepted_count() <= 0:
            raise termmeshError("configured dead socket was never contacted through SSH")
        if "Peer handshake failed" not in str(status.get("ui_summary")):
            raise termmeshError(f"failure UI summary was ambiguous: {status!r}")
        if "(reachable)" not in str(status.get("ui_discovered")):
            raise termmeshError(f"discovered endpoint reachability was not shown: {status!r}")
        warnings = status.get("ui_warnings") or []
        if not any("not substituted" in str(item) for item in warnings):
            raise termmeshError(f"silent fallback warning missing: {status!r}")

    print(
        "PASS: Test Relay keeps dead configured route failed while reporting "
        "the discovered endpoint reachable"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
