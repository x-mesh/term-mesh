#!/usr/bin/env python3
"""Peer input: kitty keyboard-protocol key reports (`CSI codepoint;mods u`)
from a viewer must be decoded and replayed, and key-RELEASE events must be
dropped (not replayed as a press).

Chain under test (`GhosttyPaneSurfaceProvider.peerCsiKeySequence` case 'u' +
`peerKittyUKeyEvent`): modifier-carrying keys a relay viewer leaves in kitty
form used to hit the "Unrecognized CSI: DROP silently" branch. Now the
codepoint maps to a macOS virtual keycode and the kitty modifier flags map to
ghostty mods, so the host pane's own encoder regenerates the right legacy
sequence for its mode. Kitty event type 3 (key release) is explicitly not a
press and returns nil (dropped).

A Ctrl+<letter> combo is used as the mapping probe because its legacy
encoding (a C0 control byte) is config-independent — unlike Alt, whose wire
form depends on the host's macos-option-as-alt setting.

Driven via `debug.peer.inject_input` and observed via
`debug.peer.replay_probe`: the pane runs `cat` with ECHO on, so ghostty's
re-encoded bytes echo back into the output tap. ECHOCTL renders C0 controls
as "^X", so the assertion accepts either the raw byte or its caret form.

Covers:
  1. Kitty Ctrl+a `\\e[97;5u` re-encodes to ^A (0x01) in the host pane pty.
  2. Kitty key-RELEASE `\\e[97;5:3u` produces NOTHING (a following plain
     sentinel key proves the pipe is alive and the release emitted no press).
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


def _has_ctrl_a(s: str) -> bool:
    return "\x01" in s or "^A" in s


def main() -> int:
    token = secrets.token_hex(4)
    marker = f"KITTYU_{token}"

    with termmesh() as c:
        sid = c.new_surface(panel_type="terminal")
        c.focus_surface(sid)
        if not _wait(lambda: c.read_terminal_text(sid).strip() != "", timeout_s=10):
            raise termmeshError(f"surface {sid} shell prompt never rendered")

        armed = c.replay_probe(sid)
        if armed.get("ok") is not True:
            raise termmeshError(f"replay_probe failed to arm surface {sid}: {armed!r}")

        script = Path(f"/tmp/tm-kitty-u-{token}.sh")
        script.write_text(f"printf '{marker}\\n'\nexec cat\n")
        c.send_surface(sid, f"sh {script}\r")
        if not _wait(lambda: marker in _probe_text(c, sid), timeout_s=8):
            raise termmeshError(
                f"cat-start marker {marker!r} never reached the pty tap. "
                f"probe:\n{_probe_text(c, sid)!r}"
            )

        # 1. Kitty Ctrl+a → ^A (0x01).
        baseline = _probe_text(c, sid)
        c.inject_peer_input(sid, b"\x1b[97;5u")
        if not _wait(lambda: _has_ctrl_a(_probe_text(c, sid)[len(baseline):]), timeout_s=8):
            raise termmeshError(
                "kitty `\\e[97;5u` (Ctrl+a) was not re-encoded into the pane pty — "
                "the peer input path is still dropping kitty-form modified keys. "
                f"post-baseline tap bytes:\n{_probe_text(c, sid)[len(baseline):]!r}"
            )

        # 2. Kitty key-RELEASE must emit nothing; a plain sentinel afterward
        #    proves the pipe is alive and the release produced no press byte.
        pre_release = _probe_text(c, sid)
        c.inject_peer_input(sid, b"\x1b[97;5:3u")   # event type 3 = release
        c.inject_peer_input(sid, b"Q")              # sentinel printable
        if not _wait(lambda: "Q" in _probe_text(c, sid)[len(pre_release):], timeout_s=8):
            raise termmeshError(
                "sentinel key 'Q' after a kitty release event never reached the "
                "pty — the release-drop path broke the ordinary key path."
            )
        release_delta = _probe_text(c, sid)[len(pre_release):]
        if _has_ctrl_a(release_delta):
            raise termmeshError(
                "kitty key-RELEASE `\\e[97;5:3u` was wrongly replayed as a Ctrl+a "
                f"press. post-release tap bytes:\n{release_delta!r}"
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
        "PASS: kitty keyboard-protocol key reports injected at the peer input "
        "seam are decoded and replayed (Ctrl+a → ^A), and key-release events "
        "are dropped instead of replayed as a press"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
