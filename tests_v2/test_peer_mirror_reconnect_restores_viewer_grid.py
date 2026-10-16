#!/usr/bin/env python3
"""After a mirror pane reconnects, the macOS host must draw at the viewer's
grid again, not at its own pane's.

When the connection that drops was the host pane's last viewer, the host
gives the PTY back to its own pane on detach. The reattach carries the
host-echoed size, and the viewer's helper reports only size changes, so
before the fix nothing told the host the viewer's grid again: the host kept
drawing at its own size. A host grid taller than the viewer pushed the remote
TUI's bottom line (a coding agent's input box) below the viewer's last row.

Topology: this app is the viewer; the staged GUI app on the remote fixture
Mac is the host (`TERMMESH_E2E_GUI_SESSION_OWNER_FIXTURE=1`). The host's
fixture pane is moved to a background workspace, so while the viewer is
attached the host grid follows the viewer exactly. The test SKIPs when the
host pane's own grid already equals the viewer's, because then a missing
resend is invisible.

Runner-only: run through `scripts/run-tests-v2.sh` on mac-sub, never on a
development host.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError
from test_remote_leader_owner_wake import (
    GUI_SESSION_OWNER_FIXTURE_ENV, fixture_root, fixture_topology_or_skip,
)
from test_remote_project_restart_reattach import _ssh_target

TOP_MARKER = "GRID-FIXTURE-TOP"
BOTTOM_MARKER = "GRID-FIXTURE-INPUT"

FIXTURE_PROGRAM = (
    "import os,signal,sys,time\n"
    "def draw(*_):\n"
    "    c,r=os.get_terminal_size()\n"
    "    sys.stdout.write('\\033[2J\\033[1;1H" + TOP_MARKER + "')\n"
    "    sys.stdout.write('\\033[%d;1H" + BOTTOM_MARKER + " cols=%d rows=%d' % (r,c,r))\n"
    "    sys.stdout.flush()\n"
    "signal.signal(signal.SIGWINCH, draw)\n"
    "sys.stdout.write('\\033[?1049h'); draw()\n"
    "while True: time.sleep(3600)\n"
)


def _wait(predicate, timeout_s: float = 30.0, interval_s: float = 0.3) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


class HostControl:
    """The staged GUI host's control socket, driven over ssh."""

    def __init__(self, ssh_target: str, control_socket: str) -> None:
        self.ssh_target = ssh_target
        self.control_socket = control_socket

    def call(self, method: str, params: dict | None = None) -> dict:
        script = (
            "import json,socket,sys\n"
            f"s=socket.socket(socket.AF_UNIX);s.connect({self.control_socket!r})\n"
            "s.sendall((json.dumps({'id':1,'method':sys.argv[1],"
            "'params':json.loads(sys.argv[2])})+'\\n').encode())\n"
            "buf=b''\n"
            "while not buf.endswith(b'\\n'):\n"
            "    chunk=s.recv(65536)\n"
            "    if not chunk: break\n"
            "    buf+=chunk\n"
            "print(buf.decode().strip())\n"
        )
        result = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=no", self.ssh_target,
             "python3", "-c", _shell_quote(script), method, _shell_quote(json.dumps(params or {}))],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            raise termmeshError(f"host {method} failed: {result.stderr.strip()}")
        reply = json.loads(result.stdout)
        if reply.get("ok") is not True:
            raise termmeshError(f"host {method} error: {reply.get('error')!r}")
        return reply.get("result") or {}


def _shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def _grid(c, surface_id: str) -> dict:
    res = c.read_grid(surface_id)
    if not res.get("ok"):
        raise termmeshError(f"viewer read_grid failed for {surface_id}: {res!r}")
    return res


def _mirror_pane(c) -> dict | None:
    panes = c.peer_mirror_status().get("panes") or []
    return panes[0] if len(panes) == 1 else None


def main() -> int:
    topology = fixture_topology_or_skip("mirror reconnect restores the viewer grid")
    if topology is None:
        return 0
    if os.environ.get(GUI_SESSION_OWNER_FIXTURE_ENV, "0").strip() != "1":
        print(f"SKIP: needs {GUI_SESSION_OWNER_FIXTURE_ENV}=1 (a staged macOS GUI host)")
        return 0
    host, remote_dir = topology
    ssh_target = _ssh_target(host)
    root = fixture_root(remote_dir)
    host_ctl = HostControl(ssh_target, f"{root}/gui-control.sock")
    host_peer_socket = f"{root}/gui-peer.sock"

    host_surfaces = host_ctl.call("surface.list").get("surfaces") or []
    if not host_surfaces:
        raise termmeshError("staged GUI host has no terminal surface")
    host_surface = str(host_surfaces[0]["id"])
    host_ctl.call("surface.send_text", {
        "surface_id": host_surface,
        "text": "python3 -c " + _shell_quote(FIXTURE_PROGRAM) + "\n",
    })
    if not _wait(lambda: BOTTOM_MARKER in (host_ctl.call(
        "debug.peer.read_grid", {"surface_id": host_surface}).get("grid_text") or ""), 20):
        raise termmeshError("host fixture never drew")
    host_own = host_ctl.call("debug.peer.read_grid", {"surface_id": host_surface})
    host_own_grid = (host_own["cols"], host_own["rows"])
    background = host_ctl.call("workspace.create", {}).get("workspace_id")
    if not background:
        raise termmeshError("host workspace.create returned no workspace_id")
    host_ctl.call("workspace.select", {"workspace_id": background})

    tunnel_dir = tempfile.mkdtemp(prefix="tm-grid-")
    local_socket = os.path.join(tunnel_dir, "peer.sock")
    tunnel = subprocess.Popen([
        "ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ExitOnForwardFailure=yes",
        "-N", "-L", f"{local_socket}:{host_peer_socket}", ssh_target,
    ])
    try:
        if not _wait(lambda: os.path.exists(local_socket), 15):
            raise termmeshError("ssh forward to the host peer socket never came up")
        with termmesh() as c:
            kicked = c._call("debug.peer.open_workspace_mirror",
                             {"sock_path": local_socket, "live": True})
            if not (kicked or {}).get("started"):
                raise termmeshError(f"live mirror kick failed: {kicked!r}")
            if not _wait(lambda: (_mirror_pane(c) or {}).get("pane_health") == "live", 60):
                raise termmeshError(f"mirror pane never went live: {c.peer_mirror_status()!r}")
            mirror_ws = c.peer_mirror_status().get("workspace_id")
            if mirror_ws:
                c.select_workspace(mirror_ws)
            pane = _mirror_pane(c)
            viewer_surface = pane["panel_id"]

            def viewer_grid() -> tuple[int, int]:
                g = _grid(c, viewer_surface)
                return (g["cols"], g["rows"])

            def host_grid() -> tuple[int, int]:
                g = host_ctl.call("debug.peer.read_grid", {"surface_id": host_surface})
                return (g["cols"], g["rows"])

            if not _wait(lambda: host_grid() == viewer_grid(), 20):
                raise termmeshError(
                    f"attached host grid {host_grid()} never followed the viewer {viewer_grid()}"
                )
            target = viewer_grid()
            if host_own_grid == target:
                print(f"SKIP: host pane grid {host_own_grid} equals the viewer's; "
                      "a missing resend would not be visible")
                return 0

            generation = int(pane["io"]["session_generation"])
            c.peer_mirror_drop_pane_transport()
            if not _wait(lambda: int(((_mirror_pane(c) or {}).get("io") or {})
                                     .get("session_generation") or 0) > generation
                         and (_mirror_pane(c) or {}).get("pane_health") == "live", 60):
                raise termmeshError(f"pane never reconnected: {c.peer_mirror_status()!r}")

            if not _wait(lambda: host_grid() == target, 15):
                raise termmeshError(
                    f"after reconnect the host kept drawing at {host_grid()}, "
                    f"viewer is {target} (host's own pane is {host_own_grid})"
                )
            expected_line = f"{BOTTOM_MARKER} cols={target[0]} rows={target[1]}"
            if not _wait(lambda: expected_line in (_grid(c, viewer_surface).get("grid_text") or ""), 15):
                raise termmeshError(
                    "viewer never showed the fixture redrawn at its own grid; "
                    f"grid_text tail={(_grid(c, viewer_surface).get('grid_text') or '')[-400:]!r}"
                )
            text = _grid(c, viewer_surface).get("grid_text") or ""
            if TOP_MARKER not in text:
                raise termmeshError(f"viewer lost the fixture's top line: {text[-400:]!r}")
            print(f"PASS: host grid {target} matches the viewer after reconnect "
                  f"(host's own pane is {host_own_grid})")
    finally:
        tunnel.terminate()
        try:
            tunnel.wait(timeout=5)
        except subprocess.TimeoutExpired:
            tunnel.kill()
        try:
            host_ctl.call("surface.send_text", {"surface_id": host_surface, "text": "\x03"})
        except termmeshError:
            pass
        for leftover in (local_socket,):
            if os.path.exists(leftover):
                os.unlink(leftover)
        os.rmdir(tunnel_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
