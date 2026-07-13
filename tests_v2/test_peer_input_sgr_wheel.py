#!/usr/bin/env python3
"""Peer input: SGR mouse WHEEL reports from a viewer must reach the host
pane's pty instead of dying in the unrecognized-CSI drop branch.

Chain under test (`GhosttyPaneSurfaceProvider.sendPeerInputBytes`):
the attach-time DECSET replay (48efa7cd) puts a relay viewer in
mouse-captured mode, so its wheel arrives at the host as SGR press
reports (`\\e[<64;col;rowM`). Before the fix those fell through to the
"Unrecognized CSI: DROP silently" branch — the reason peer viewers could
not scroll Claude Code / vim even after the mode replay fix. Now they are
re-dispatched through `ghostty_surface_mouse_scroll` (after warping the
cursor to the reported cell so mouse_encode.zig's out-of-viewport guard
does not drop the re-encode), and ghostty re-encodes them for the host
pane's real mouse mode, writing the report to the pane's pty input.

There is no live 2-node peer session in this environment, so the input
leg is driven via `debug.peer.inject_input` (the exact seam a peer
client's Input frame enters) and observed via `debug.peer.replay_probe`'s
raw ring-buffer bytes: the pane runs `cat` with ECHO on, so whatever
ghostty writes to the pty input is echoed back into the pty OUTPUT tap.

Covers:
  1. Pane with mouse reporting enabled (?1002h?1006h, like Claude Code):
     injected `\\e[<64;10;10M` produces a re-encoded SGR wheel report in
     the output stream ("[<64;" substring — ECHOCTL may render ESC as
     "^[", so only the CSI body is asserted).
  2. Wheel-down (65) round-trips too, and plain keys injected alongside
     still arrive (the fix must not break the existing key path).
"""
import secrets
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


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


def main() -> int:
    token = secrets.token_hex(4)
    marker = f"SGRWHEEL_{token}"

    with termmesh() as c:
        sid = c.new_surface(panel_type="terminal")
        c.focus_surface(sid)
        if not _wait(lambda: c.read_terminal_text(sid).strip() != "", timeout_s=10):
            raise termmeshError(f"surface {sid} shell prompt never rendered")

        # Arm the PTY tap ring buffer BEFORE any interesting output flows.
        armed = c.replay_probe(sid)
        if armed.get("ok") is not True:
            raise termmeshError(f"replay_probe failed to arm surface {sid}: {armed!r}")

        # Put the pane in the Claude Code shape: mouse reporting on
        # (button-event tracking + SGR encoding), then hold the pty open
        # with cat so injected input echoes back into the output tap.
        # The DECSET escapes go through a script file instead of being
        # typed into the pty: interactive-shell integrations (kitty
        # keyboard mode, Warp hooks) can mangle a typed `\\033[?` literal.
        script = Path(f"/tmp/tm-sgr-wheel-{token}.sh")
        script.write_text(
            f"printf '\\033[?1002h\\033[?1006h{marker}\\n'\nexec cat\n"
        )
        c.send_surface(sid, f"sh {script}\r")
        if not _wait(lambda: marker in _probe_text(c, sid), timeout_s=8):
            raise termmeshError(
                f"mouse-enable marker {marker!r} never reached the pty tap. "
                f"probe:\n{_probe_text(c, sid)!r}"
            )
        baseline = _probe_text(c, sid)

        # 1. Inject a wheel-up SGR report through the peer input seam.
        c.inject_peer_input(sid, b"\x1b[<64;10;10M")

        # The fixed host re-encodes the wheel for the pane's mouse mode and
        # writes it to the pty input; cat's tty echoes it into the output
        # tap. ECHOCTL may render ESC as "^[", so assert the CSI body only.
        if not _wait(lambda: "[<64;" in _probe_text(c, sid)[len(baseline):], timeout_s=8):
            raise termmeshError(
                "wheel-up SGR report was not re-encoded into the pane pty — "
                "the peer input path is still dropping SGR mouse reports. "
                f"post-baseline tap bytes:\n{_probe_text(c, sid)[len(baseline):]!r}"
            )

        # 2. Wheel-down round-trips, and a plain key still passes.
        pre_down = _probe_text(c, sid)
        c.inject_peer_input(sid, b"\x1b[<65;10;10M")
        if not _wait(lambda: "[<65;" in _probe_text(c, sid)[len(pre_down):], timeout_s=8):
            raise termmeshError(
                "wheel-down SGR report was not re-encoded into the pane pty. "
                f"post-baseline tap bytes:\n{_probe_text(c, sid)[len(pre_down):]!r}"
            )

        key_marker = f"KEYOK_{token}"
        pre_key = _probe_text(c, sid)
        c.inject_peer_input(sid, key_marker.encode())
        if not _wait(lambda: key_marker in _probe_text(c, sid)[len(pre_key):], timeout_s=8):
            raise termmeshError(
                f"plain key injection {key_marker!r} no longer reaches the pty — "
                "the SGR wheel branch broke the ordinary key path."
            )

        try:
            c.close_surface(sid)
        except termmeshError:
            pass
        try:
            script.unlink()
        except OSError:
            pass

    print(
        "PASS: SGR wheel reports injected at the peer input seam are "
        "re-encoded into the host pane pty (up + down), and plain key "
        "injection still works alongside them"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
