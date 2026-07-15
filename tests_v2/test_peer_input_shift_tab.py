#!/usr/bin/env python3
"""Peer input: Shift+Tab (back-tab) from a viewer must reach the host pane's
pty instead of dying in the unrecognized-CSI drop branch.

Chain under test (`GhosttyPaneSurfaceProvider.peerCsiKeySequence`): a relay
viewer's Shift+Tab arrives in one of two wire forms — the legacy CBT
`\\e[Z` (bare, implicit Shift) or the kitty-keyboard form `\\e[9;2u`
(codepoint 9 = Tab, modifier 2 = Shift). Before the fix BOTH fell through
to the "Unrecognized CSI: DROP silently" branch, so reverse navigation
(menus / vim / Claude Code Shift+Tab) was dead over the relay. Now each is
decoded to keycode kVK_Tab (0x30) + Shift and replayed through the host
pane's own key encoder, which regenerates `\\e[Z` for the pane's mode.

There is no live 2-node peer session in this environment, so the input leg
is driven via `debug.peer.inject_input` (the exact seam a peer client's
Input frame enters) and observed via `debug.peer.replay_probe`'s raw
ring-buffer bytes: the pane runs `cat` with ECHO on, so whatever ghostty
writes to the pty input is echoed back into the pty OUTPUT tap. ECHOCTL may
render ESC as "^[", so only the CSI body "[Z" is asserted.

Covers:
  1. Legacy CBT `\\e[Z` re-encodes to a back-tab in the host pane pty.
  2. Kitty-form `\\e[9;2u` re-encodes to the same back-tab.
  3. A plain key injected alongside still arrives (the new 'Z'/'u' CSI
     branches must not break the existing key path).
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
    marker = f"SHIFTTAB_{token}"

    with termmesh() as c:
        sid = c.new_surface(panel_type="terminal")
        c.focus_surface(sid)
        if not _wait(lambda: c.read_terminal_text(sid).strip() != "", timeout_s=10):
            raise termmeshError(f"surface {sid} shell prompt never rendered")

        armed = c.replay_probe(sid)
        if armed.get("ok") is not True:
            raise termmeshError(f"replay_probe failed to arm surface {sid}: {armed!r}")

        # Hold the pty open with cat (ECHO on) so injected input echoes back
        # into the output tap. Go through a script file so interactive-shell
        # integrations don't mangle the printf.
        script = Path(f"/tmp/tm-shift-tab-{token}.sh")
        script.write_text(f"printf '{marker}\\n'\nexec cat\n")
        c.send_surface(sid, f"sh {script}\r")
        if not _wait(lambda: marker in _probe_text(c, sid), timeout_s=8):
            raise termmeshError(
                f"cat-start marker {marker!r} never reached the pty tap. "
                f"probe:\n{_probe_text(c, sid)!r}"
            )

        # 1. Legacy CBT back-tab.
        baseline = _probe_text(c, sid)
        c.inject_peer_input(sid, b"\x1b[Z")
        if not _wait(lambda: "[Z" in _probe_text(c, sid)[len(baseline):], timeout_s=8):
            raise termmeshError(
                "legacy `\\e[Z` Shift+Tab was not re-encoded into the pane pty — "
                "the peer input path is still dropping back-tab. "
                f"post-baseline tap bytes:\n{_probe_text(c, sid)[len(baseline):]!r}"
            )

        # 2. Kitty-form Shift+Tab (codepoint 9, modifier 2).
        pre_kitty = _probe_text(c, sid)
        c.inject_peer_input(sid, b"\x1b[9;2u")
        if not _wait(lambda: "[Z" in _probe_text(c, sid)[len(pre_kitty):], timeout_s=8):
            raise termmeshError(
                "kitty-form `\\e[9;2u` Shift+Tab was not re-encoded into the pane "
                "pty. post-baseline tap bytes:\n"
                f"{_probe_text(c, sid)[len(pre_kitty):]!r}"
            )

        # 3. A plain key still passes.
        key_marker = f"KEYOK_{token}"
        pre_key = _probe_text(c, sid)
        c.inject_peer_input(sid, key_marker.encode())
        if not _wait(lambda: key_marker in _probe_text(c, sid)[len(pre_key):], timeout_s=8):
            raise termmeshError(
                f"plain key injection {key_marker!r} no longer reaches the pty — "
                "the Shift+Tab CSI branch broke the ordinary key path."
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
        "PASS: Shift+Tab injected at the peer input seam (legacy `\\e[Z` and "
        "kitty `\\e[9;2u`) is re-encoded into the host pane pty, and plain key "
        "injection still works alongside it"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
