#!/usr/bin/env python3
"""Peer input: SGR mouse BUTTON / MOTION / RELEASE reports from a viewer must
reach the host pane's pty so remote users can select and drag, not just
scroll.

Chain under test (`GhosttyPaneSurfaceProvider.sendPeerInputBytes` +
`peerSgrButtonReport`): the wheel branch (test_peer_input_sgr_wheel) already
re-dispatches wheel reports; press/drag/release reports used to fall through
to the "Unrecognized CSI: DROP silently" branch — the reason peer viewers
could scroll Claude Code / vim but never select or drag. Now a button report
warps the host surface's real cursor to the reported cell
(`ghostty_surface_mouse_pos`) and, for a press/release, forwards a real
button event (`ghostty_surface_mouse_button`). The host core re-encodes for
the pane's actual mouse mode, writing the report to the pane pty input.

Driven through a real peer connection. A tiny raw-mode test TUI enables
button-event mouse tracking (?1002h) + SGR encoding (?1006h), then prints each
report it receives as hex. This covers Ghostty's complete decode, cursor warp,
button dispatch, and pty re-encoding path.

Covers:
  1. Real peer Resize transitions 41×13 → 40×12 produce exact host grids.
  2. Left-button PRESS  `\\e[<0;C;RM`  → the exact same SGR coordinates.
  3. Button-held MOTION `\\e[<32;C;RM` → the exact same drag coordinates — the
     drag the host core emits because the earlier press is still held.
  4. Bottom-row RELEASE `\\e[<0;C;12m` → row 12 remains addressable.
"""
import os
import secrets
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError
import peer_client as pc
from peer_client import PeerClient


def _wait(predicate, timeout_s: float = 10.0, interval_s: float = 0.1) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def _probe_text(c, sid) -> str:
    probe = c.replay_probe(sid)
    if probe.get("ok") is not True:
        return ""
    return str(probe.get("bytes_text") or "")


def _grid_is(c, sid, cols: int, rows: int) -> bool:
    grid = c.read_grid(sid)
    return grid.get("cols") == cols and grid.get("rows") == rows


def _send_peer_resize(peer, sid_bytes: bytes, cols: int, rows: int) -> None:
    peer._send(
        resize=pc.pb.Resize(
            surface_id=sid_bytes,
            cols=cols,
            rows=rows,
            pixel_width=0,
            pixel_height=0,
            claim_authority=True,
        )
    )


def _send_peer_keys(peer, sid_bytes: bytes, keys: bytes) -> None:
    peer._send(input=pc.pb.Input(surface_id=sid_bytes, keys=keys))


def main() -> int:
    token = secrets.token_hex(4)
    marker = f"SGRBTN_{token}"
    rearm_marker = f"SGRBTN_REARM_{token}"

    with termmesh() as c:
        sid = c.new_surface(panel_type="terminal")
        c.focus_surface(sid)
        if not _wait(lambda: c.read_terminal_text(sid).strip() != "", timeout_s=10):
            raise termmeshError(f"surface {sid} shell prompt never rendered")

        armed = c.replay_probe(sid)
        if armed.get("ok") is not True:
            raise termmeshError(f"replay_probe failed to arm surface {sid}: {armed!r}")

        # The raw-mode helper re-arms mouse tracking after resize and renders
        # each pty input report as printable hex for deterministic observation.
        script = Path(f"/tmp/tm-sgr-btn-{token}.py")
        repaint_trigger = Path(f"/tmp/tm-sgr-btn-repaint-{token}")
        script.write_text(
            "import os, sys, time, tty\n"
            "tty.setraw(0)\n"
            f"sys.stdout.write('\\x1b[?1002h\\x1b[?1006h{marker}\\r\\n')\n"
            "sys.stdout.flush()\n"
            f"while not os.path.exists({str(repaint_trigger)!r}): time.sleep(0.05)\n"
            f"sys.stdout.write('\\x1b[2J\\x1b[H\\x1b[?1002h\\x1b[?1006h{rearm_marker}\\r\\n')\n"
            "sys.stdout.flush()\n"
            "buf = b''\n"
            "while True:\n"
            "    data = os.read(0, 128)\n"
            "    if not data: break\n"
            "    buf += data\n"
            "    while True:\n"
            "        start = buf.find(b'\\x1b[<')\n"
            "        if start < 0:\n"
            "            buf = buf[-2:]\n"
            "            break\n"
            "        buf = buf[start:]\n"
            "        ends = [p for p in (buf.find(b'M'), buf.find(b'm')) if p >= 0]\n"
            "        if not ends: break\n"
            "        end = min(ends)\n"
            "        report, buf = buf[:end + 1], buf[end + 1:]\n"
            "        sys.stdout.write('EVENT_HEX:' + report.hex() + '\\r\\n')\n"
            "        sys.stdout.flush()\n"
        )
        c.send_surface(sid, f"python3 {script}\r")
        if not _wait(lambda: marker in _probe_text(c, sid), timeout_s=8):
            raise termmeshError(
                f"mouse-enable marker {marker!r} never reached the pty tap. "
                f"probe:\n{_probe_text(c, sid)!r}"
            )

        daemon_socket = os.environ["TERMMESH_DAEMON_UNIX_PATH"]
        peer_socket = daemon_socket.removesuffix(".sock") + "-app-peer.sock"
        if not _wait(lambda: Path(peer_socket).exists(), timeout_s=10):
            raise termmeshError(f"peer socket never appeared at {peer_socket}")
        peer = PeerClient(peer_socket, display_name="sgr-button-test")
        peer.connect()
        peer.handshake()
        sid_bytes = uuid.UUID(str(sid)).bytes
        peer.attach_surface(sid_bytes)

        # Prove the Resize is observable rather than accepting an initial grid
        # that happened to have the requested dimensions. The sentinel first
        # forces a distinct state, then the target must resolve exactly too.
        _send_peer_resize(peer, sid_bytes, 41, 13)
        if not _wait(lambda: _grid_is(c, sid, 41, 13), timeout_s=8):
            grid = c.read_grid(sid)
            raise termmeshError(
                "peer sentinel Resize(41,13) did not produce an exact host grid: "
                f"actual=({grid.get('cols')},{grid.get('rows')})"
            )
        _send_peer_resize(peer, sid_bytes, 40, 12)
        if not _wait(lambda: _grid_is(c, sid, 40, 12), timeout_s=8):
            grid = c.read_grid(sid)
            raise termmeshError(
                "peer Resize(40,12) did not produce an exact host grid: "
                f"actual=({grid.get('cols')},{grid.get('rows')})"
            )

        # Trigger the test TUI's deterministic post-resize repaint and require
        # its marker before testing mouse reports. This avoids asserting
        # against the pre-resize mouse mode or replay bytes.
        repaint_trigger.write_text("")
        if not _wait(
            lambda: rearm_marker in c.read_terminal_text(sid),
            timeout_s=8,
        ):
            raise termmeshError(
                "test TUI did not re-arm mouse mode after resize. "
                f"screen:\n{c.read_terminal_text(sid)!r}"
            )

        # 1. Left-button PRESS at cell (5,3).
        press = b"\x1b[<0;5;3M"
        _send_peer_keys(peer, sid_bytes, press)
        expected_press = "EVENT_HEX:" + press.hex()
        if not _wait(
            lambda: expected_press in c.read_terminal_text(sid),
            timeout_s=8,
        ):
            raise termmeshError(
                "left-button PRESS SGR coordinates changed during relay input. "
                f"expected={expected_press!r} screen:\n{c.read_terminal_text(sid)!r}"
            )

        # 2. Button-held MOTION to the bottom row (7,12) → drag report.
        motion = b"\x1b[<32;7;12M"
        _send_peer_keys(peer, sid_bytes, motion)
        expected_motion = "EVENT_HEX:" + motion.hex()
        if not _wait(
            lambda: expected_motion in c.read_terminal_text(sid),
            timeout_s=8,
        ):
            raise termmeshError(
                "button-held MOTION SGR coordinates changed during relay input. "
                f"expected={expected_motion!r} screen:\n{c.read_terminal_text(sid)!r}"
            )

        # 3. Button RELEASE at the bottom row (9,12) → lowercase-m report.
        release = b"\x1b[<0;9;12m"
        _send_peer_keys(peer, sid_bytes, release)
        expected_release = "EVENT_HEX:" + release.hex()
        if not _wait(
            lambda: expected_release in c.read_terminal_text(sid),
            timeout_s=8,
        ):
            raise termmeshError(
                "button RELEASE SGR coordinates changed during relay input. "
                f"expected={expected_release!r} screen:\n{c.read_terminal_text(sid)!r}"
            )

        peer.detach_surface(sid_bytes)
        peer.close()
        try:
            c.close_surface(sid)
        except termmeshError:
            pass
        try:
            script.unlink()
        except OSError:
            pass
        try:
            repaint_trigger.unlink()
        except OSError:
            pass

    print(
        "PASS: peer resize preserves the exact host grid and SGR mouse "
        "press/motion/release coordinates round-trip unchanged"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
