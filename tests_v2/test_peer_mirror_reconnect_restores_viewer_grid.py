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
fixture pane is moved to a background workspace, so while a viewer is
attached the host grid follows the viewer exactly. The test owns the ssh
forward the mirror dials, so it can hold the reconnect open long enough to
observe the detach: the host grid must fall back to the host pane's own grid
while no viewer is attached, and must return to the viewer's grid after the
pane reconnects. It SKIPs when the host pane's own grid already equals the
viewer's, because then a missing resend is invisible.

Runner-only: run through `scripts/run-tests-v2.sh` on mac-sub, never on a
development host.
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError
from test_remote_leader_owner_wake import (
    GUI_SESSION_OWNER_FIXTURE_ENV, fixture_root, fixture_topology_or_skip,
)
from test_remote_project_restart_reattach import _ssh_target

TOP_MARKER = "GRID-FIXTURE-TOP"
BOTTOM_MARKER = "GRID-FIXTURE-INPUT"
FIXTURE_FILE = "grid_fixture.py"

FIXTURE_PROGRAM = (
    "import os,signal,sys,time\n"
    "def draw(*_):\n"
    "    c,r=os.get_terminal_size()\n"
    "    sys.stdout.write('\\033[2J\\033[1;1H" + TOP_MARKER + "')\n"
    "    sys.stdout.write('\\033[%d;1H" + BOTTOM_MARKER + " cols=%d rows=%d' % (r,c,r))\n"
    "    sys.stdout.flush()\n"
    "signal.signal(signal.SIGWINCH, draw)\n"
    "sys.stdout.write('\\033[?1049h'); draw()\n"
    "try:\n"
    "    while True: time.sleep(3600)\n"
    "finally:\n"
    "    sys.stdout.write('\\033[?1049l'); sys.stdout.flush()\n"
)

HOST_CALL_SCRIPT = """\
import json, socket
s = socket.socket(socket.AF_UNIX)
s.connect({socket!r})
s.sendall((json.dumps({{"id": 1, "method": {method!r}, "params": json.loads({params!r})}}) + "\\n").encode())
buf = b""
while not buf.endswith(b"\\n"):
    chunk = s.recv(65536)
    if not chunk:
        break
    buf += chunk
print(buf.decode(errors="replace").strip())
"""


def _wait(predicate, timeout_s: float = 30.0, interval_s: float = 0.3) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def _ssh(ssh_target: str, args: list[str], stdin: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none",
         ssh_target, *args],
        input=stdin, capture_output=True, text=True, timeout=30,
    )


class HostControl:
    """The staged GUI host's control socket, driven over ssh.

    The request travels on stdin to `python3 -`, so no part of it passes
    through the remote login shell's quoting rules (zsh or bash alike).
    """

    def __init__(self, ssh_target: str, control_socket: str) -> None:
        self.ssh_target = ssh_target
        self.control_socket = control_socket

    def call(self, method: str, params: dict | None = None) -> dict:
        script = HOST_CALL_SCRIPT.format(
            socket=self.control_socket, method=method, params=json.dumps(params or {}),
        )
        result = _ssh(self.ssh_target, ["python3", "-"], stdin=script)
        raw = result.stdout.strip()
        try:
            reply = json.loads(raw)
        except json.JSONDecodeError:
            raise termmeshError(
                f"host {method} returned non-JSON (exit {result.returncode}): "
                f"stdout={raw[:300]!r} stderr={result.stderr.strip()[:300]!r}"
            ) from None
        if reply.get("ok") is not True:
            raise termmeshError(f"host {method} error: {reply.get('error')!r}")
        return reply.get("result") or {}

    def grid(self, surface_id: str) -> tuple[int, int, str]:
        g = self.call("debug.peer.read_grid", {"surface_id": surface_id})
        if not g.get("ok"):
            raise termmeshError(f"host read_grid failed for {surface_id}: {g!r}")
        return int(g["cols"]), int(g["rows"]), str(g.get("grid_text") or "")

    def run_python(self, script: str) -> None:
        result = _ssh(self.ssh_target, ["python3", "-"], stdin=script)
        if result.returncode != 0:
            raise termmeshError(f"host python failed: {result.stderr.strip()[:300]!r}")

    def install_fixture(self, path: str) -> None:
        self.run_python(f"open({path!r}, 'w').write({FIXTURE_PROGRAM!r})\n")

    def kill_fixture(self, path: str) -> None:
        # The bracket keeps pkill from matching this script's own command line.
        pattern = "[" + path[0] + "]" + path[1:]
        self.run_python(f"import subprocess\nsubprocess.run(['pkill', '-f', {pattern!r}])\n")


class Forward:
    """The ssh forward the mirror dials. Stopping it drops the viewer's
    transport and keeps every redial failing until it is started again on the
    same local path."""

    def __init__(self, ssh_target: str, remote_socket: str, local_socket: str) -> None:
        self.ssh_target = ssh_target
        self.remote_socket = remote_socket
        self.local_socket = local_socket
        self.proc: subprocess.Popen | None = None

    def start(self) -> None:
        if os.path.exists(self.local_socket):
            os.unlink(self.local_socket)
        self.proc = subprocess.Popen([
            "ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "ExitOnForwardFailure=yes",
            "-N", "-L", f"{self.local_socket}:{self.remote_socket}", self.ssh_target,
        ])
        if not _wait(lambda: os.path.exists(self.local_socket), 15):
            raise termmeshError("ssh forward to the host peer socket never came up")

    def stop(self) -> None:
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
            self.proc = None
        if os.path.exists(self.local_socket):
            os.unlink(self.local_socket)


def _mirror_pane(c) -> dict | None:
    panes = c.peer_mirror_status().get("panes") or []
    return panes[0] if len(panes) == 1 else None


def _generation(c) -> int:
    return int(((_mirror_pane(c) or {}).get("io") or {}).get("session_generation") or 0)


def _viewer_grid(c, surface_id: str) -> tuple[int, int, str]:
    g = c.read_grid(surface_id)
    if not g.get("ok"):
        raise termmeshError(f"viewer read_grid failed for {surface_id}: {g!r}")
    return int(g["cols"]), int(g["rows"]), str(g.get("grid_text") or "")


def run(c, host_ctl: HostControl, forward: Forward, host_surface: str,
        host_own: tuple[int, int]) -> None:
    forward.start()
    kicked = c._call("debug.peer.open_workspace_mirror",
                     {"sock_path": forward.local_socket, "live": True})
    if not (kicked or {}).get("started"):
        raise termmeshError(f"live mirror kick failed: {kicked!r}")
    if not _wait(lambda: (_mirror_pane(c) or {}).get("pane_health") == "live", 60):
        raise termmeshError(f"mirror pane never went live: {c.peer_mirror_status()!r}")
    pane = _mirror_pane(c)
    expected_surface = base64.b64encode(uuid.UUID(host_surface).bytes).decode()
    if pane["surface_id"] != expected_surface:
        raise termmeshError(f"mirror attached {pane['surface_id']}, expected the fixture {expected_surface}")
    mirror_ws = c.peer_mirror_status().get("workspace_id")
    if mirror_ws:
        c.select_workspace(mirror_ws)
    viewer_surface = pane["panel_id"]

    def host_size() -> tuple[int, int]:
        return host_ctl.grid(host_surface)[:2]

    def viewer_size() -> tuple[int, int]:
        return _viewer_grid(c, viewer_surface)[:2]

    if not _wait(lambda: host_size() == viewer_size(), 20):
        raise termmeshError(f"attached host grid {host_size()} never followed the viewer {viewer_size()}")
    target = viewer_size()
    if host_own == target:
        print(f"SKIP: host pane grid {host_own} equals the viewer's; a missing resend would not be visible")
        return

    generation_before = _generation(c)
    forward.stop()
    if not _wait(lambda: host_size() == host_own, 20):
        raise termmeshError(
            f"with no viewer attached the host grid stayed {host_size()}, "
            f"expected its own {host_own}; the detach this test depends on never happened"
        )
    print(f"detach observed: host grid fell back to its own {host_own}")
    forward.start()
    if not _wait(lambda: _generation(c) > generation_before
                 and (_mirror_pane(c) or {}).get("pane_health") == "live", 90):
        raise termmeshError(
            f"pane never reconnected past session_generation {generation_before}: {c.peer_mirror_status()!r}"
        )
    print(f"reconnected: session_generation {generation_before} -> {_generation(c)}")

    if not _wait(lambda: host_size() == target, 15):
        raise termmeshError(
            f"after reconnect the host grid stayed {host_size()} but the viewer is {target} "
            f"(host's own pane is {host_own})"
        )
    expected_line = f"{BOTTOM_MARKER} cols={target[0]} rows={target[1]}"
    if not _wait(lambda: expected_line in _viewer_grid(c, viewer_surface)[2], 15):
        raise termmeshError(
            "viewer never showed the fixture redrawn at its own grid; "
            f"grid_text tail={_viewer_grid(c, viewer_surface)[2][-400:]!r}"
        )
    if TOP_MARKER not in _viewer_grid(c, viewer_surface)[2]:
        raise termmeshError("viewer lost the fixture's top line after reconnect")
    print(f"PASS: host grid {target} matches the viewer after reconnect (host's own pane is {host_own})")


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

    workspaces = host_ctl.call("workspace.list").get("workspaces") or []
    original_ws = next((str(w["id"]) for w in workspaces if w.get("selected")), None)
    if not original_ws:
        raise termmeshError(f"staged GUI host reports no selected workspace: {workspaces!r}")
    host_surfaces = host_ctl.call("surface.list", {"workspace_id": original_ws}).get("surfaces") or []
    if not host_surfaces:
        raise termmeshError("staged GUI host has no terminal surface")
    host_surface = str(host_surfaces[0]["id"])

    tunnel_dir = tempfile.mkdtemp(prefix="tm-grid-")
    forward = Forward(ssh_target, f"{root}/gui-peer.sock", os.path.join(tunnel_dir, "peer.sock"))
    fixture_path = f"{root}/{FIXTURE_FILE}"
    background_ws: str | None = None
    try:
        host_ctl.install_fixture(fixture_path)
        host_ctl.call("surface.send_text", {
            "surface_id": host_surface,
            "text": f"python3 {fixture_path}\n",
        })
        if not _wait(lambda: BOTTOM_MARKER in host_ctl.grid(host_surface)[2], 20):
            raise termmeshError(f"host fixture never drew: {host_ctl.grid(host_surface)[2][-300:]!r}")
        host_own = host_ctl.grid(host_surface)[:2]
        background_ws = host_ctl.call("workspace.create", {}).get("workspace_id")
        if not background_ws:
            raise termmeshError("host workspace.create returned no workspace_id")
        host_ctl.call("workspace.select", {"workspace_id": background_ws})
        with termmesh() as c:
            run(c, host_ctl, forward, host_surface, host_own)
    finally:
        forward.stop()
        os.rmdir(tunnel_dir)
        cleanup = [
            lambda: host_ctl.kill_fixture(fixture_path),
            lambda: host_ctl.call("workspace.select", {"workspace_id": original_ws}),
        ]
        if background_ws:
            cleanup.append(lambda: host_ctl.call("workspace.close", {"workspace_id": background_ws}))
        for step in cleanup:
            try:
                step()
            except (termmeshError, subprocess.TimeoutExpired) as exc:
                print(f"WARN: host cleanup step failed: {exc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
