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

Driven via `debug.peer.inject_input` and observed via
`debug.peer.replay_probe`: the pane enables button-event mouse tracking
(?1002h) + SGR encoding (?1006h) and runs `cat` with ECHO on, so ghostty's
re-encoded reports echo back into the output tap. ECHOCTL may render ESC as
"^[", so only the CSI bodies are asserted.

Covers:
  1. Left-button PRESS  `\\e[<0;C;RM`  → SGR press report ("[<0;") in the pty.
  2. Button-held MOTION `\\e[<32;C;RM` → SGR drag report ("[<32;") — the
     drag the host core emits because a button is still held from step 1.
  3. Button RELEASE     `\\e[<0;C;Rm`  → SGR release report (lowercase-m
     terminated) in the pty.
"""
import re
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
    marker = f"SGRBTN_{token}"

    with termmesh() as c:
        sid = c.new_surface(panel_type="terminal")
        c.focus_surface(sid)
        if not _wait(lambda: c.read_terminal_text(sid).strip() != "", timeout_s=10):
            raise termmeshError(f"surface {sid} shell prompt never rendered")

        armed = c.replay_probe(sid)
        if armed.get("ok") is not True:
            raise termmeshError(f"replay_probe failed to arm surface {sid}: {armed!r}")

        # Button-event tracking (?1002h) + SGR (?1006h), then hold the pty open
        # with cat so re-encoded reports echo back into the output tap. The
        # DECSET escapes go through a script file so shell integrations don't
        # mangle the literal `\\033[?`.
        script = Path(f"/tmp/tm-sgr-btn-{token}.sh")
        script.write_text(
            f"printf '\\033[?1002h\\033[?1006h{marker}\\n'\nexec cat\n"
        )
        c.send_surface(sid, f"sh {script}\r")
        if not _wait(lambda: marker in _probe_text(c, sid), timeout_s=8):
            raise termmeshError(
                f"mouse-enable marker {marker!r} never reached the pty tap. "
                f"probe:\n{_probe_text(c, sid)!r}"
            )

        # 1. Left-button PRESS at cell (5,3).
        baseline = _probe_text(c, sid)
        c.inject_peer_input(sid, b"\x1b[<0;5;3M")
        if not _wait(lambda: "[<0;" in _probe_text(c, sid)[len(baseline):], timeout_s=8):
            raise termmeshError(
                "left-button PRESS SGR report was not re-encoded into the pane "
                "pty — the peer input path is still dropping mouse buttons. "
                f"post-baseline tap bytes:\n{_probe_text(c, sid)[len(baseline):]!r}"
            )

        # 2. Button-held MOTION to a DIFFERENT cell (7,3) → drag report.
        pre_motion = _probe_text(c, sid)
        c.inject_peer_input(sid, b"\x1b[<32;7;3M")
        if not _wait(lambda: "[<32;" in _probe_text(c, sid)[len(pre_motion):], timeout_s=8):
            raise termmeshError(
                "button-held MOTION SGR report was not re-encoded into the pane "
                "pty — drag selection is still dropped over the relay. "
                f"post-baseline tap bytes:\n{_probe_text(c, sid)[len(pre_motion):]!r}"
            )

        # 3. Button RELEASE at cell (9,3) → lowercase-m terminated SGR report.
        pre_release = _probe_text(c, sid)
        c.inject_peer_input(sid, b"\x1b[<0;9;3m")
        if not _wait(
            lambda: re.search(r"\[<\d+;\d+;\d+m", _probe_text(c, sid)[len(pre_release):]),
            timeout_s=8,
        ):
            raise termmeshError(
                "button RELEASE SGR report (lowercase-m) was not re-encoded into "
                "the pane pty. post-baseline tap bytes:\n"
                f"{_probe_text(c, sid)[len(pre_release):]!r}"
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
        "PASS: SGR mouse press/motion/release injected at the peer input seam "
        "are re-encoded into the host pane pty — remote select and drag now "
        "reach the host, not just wheel scroll"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
