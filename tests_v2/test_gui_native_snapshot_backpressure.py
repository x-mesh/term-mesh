#!/usr/bin/env python3
"""Large GUI native snapshots remain exact across more than 64 cumulative attachments."""
import json
import hashlib
import os
import subprocess
import time
from pathlib import Path

from termmesh import termmesh, termmeshError


def main() -> int:
    snapshot_bytes = 2 * 1024 * 1024
    cycles = 14
    receipt = {"snapshot_bytes": snapshot_bytes, "reconnects": []}
    control_socket = os.environ.get("TERMMESH_SOCKET_PATH", os.environ.get("TERMMESH_SOCKET", ""))
    owner = subprocess.check_output(["/usr/sbin/lsof", "-t", control_socket], text=True).strip()
    if not owner.isdigit():
        raise termmeshError(f"control socket must have one owner: {owner!r}")
    receipt["topology"] = {
        "hostname": subprocess.check_output(["hostname"], text=True).strip(),
        "checkout": str(Path.cwd()),
        "base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "control_socket": control_socket,
        "app_pid": int(owner),
        "app_command": subprocess.check_output(["ps", "-p", owner, "-o", "command="], text=True).strip(),
        "daemon_socket": os.environ.get("TERMMESH_DAEMON_UNIX_PATH", ""),
        "app_peer_socket": os.environ.get("TERMMESH_PEER_SERVER_PATH", ""),
        "source_hashes": {
            path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
            for path in ("Sources/RemoteLiveProject.swift",
                         "swift/PeerProto/Sources/PeerProto/PeerServer.swift")
        },
    }
    with termmesh() as client:
        def call(action="status", **params):
            return client._call("debug.project.live_fixture", {"action": action, **params})

        def wait(predicate, description, timeout=60):
            deadline = time.monotonic() + timeout
            last = None
            while time.monotonic() < deadline:
                last = call()
                if last.get("failure"):
                    raise termmeshError(f"{description}: {last}")
                if predicate(last):
                    return last
                time.sleep(0.1)
            raise termmeshError(f"timed out waiting for {description}: {last}")

        def ready(status):
            return (not status["starting"] and status["viewer_panels"] == 6
                    and status["source_panels"] == 6 and status["matching_transcripts"] == 5
                    and status["active_viewer_agents"] == 5
                    and status["server_active_sessions"] > 0)

        try:
            call("start", snapshot_bytes=snapshot_bytes)
            initial = wait(ready, "the full native snapshot")
            if initial["snapshot_bytes"] != snapshot_bytes:
                raise termmeshError(f"large snapshot was not configured: {initial}")
            baseline = initial["server_active_sessions"]
            receipt["initial"] = initial
            previous = initial
            for cycle in range(cycles):
                call("reconnect")
                current = wait(
                    lambda status: ready(status)
                    and set(status["viewer_agent_ids"]).isdisjoint(previous["viewer_agent_ids"])
                    and status["server_active_sessions"] <= baseline,
                    f"reconnect {cycle + 1} with reclaimed server sessions",
                )
                if current["source_agent_ids"] != initial["source_agent_ids"]:
                    raise termmeshError(f"reconnect replaced an owner agent: {current}")
                receipt["reconnects"].append({
                    "cycle": cycle + 1,
                    "server_sessions": current["server_active_sessions"],
                    "matching_transcripts": current["matching_transcripts"],
                    "viewer_agent_ids": current["viewer_agent_ids"],
                })
                previous = current
            call("send")
            final = wait(lambda status: ready(status) and status["input_echoes"] == 1,
                         "live input after repeated full snapshots")
            receipt["final"] = final
            subprocess.Popen(["/usr/bin/caffeinate", "-u", "-t", "10"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            client._call("debug.app.activate", {})
            subprocess.run(["/usr/sbin/screencapture", "-x",
                            "/tmp/term-mesh-native-snapshot-e2e.png"], check=True)
        finally:
            call("cleanup")
            cleaned = wait(lambda status: not status["cleaning"] and status["viewer_id"] == ""
                           and status["server_active_sessions"] == 0,
                           "fixture cleanup")
            receipt["cleanup"] = cleaned
            Path("/tmp/term-mesh-native-snapshot-e2e.json").write_text(
                json.dumps(receipt, ensure_ascii=False, indent=2) + "\n"
            )
    print("PASS: 2 MiB native snapshot stays exact across 14 reconnects without retained server sessions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
