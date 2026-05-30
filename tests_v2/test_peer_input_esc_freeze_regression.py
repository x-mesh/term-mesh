#!/usr/bin/env python3
"""Peer-relay host input: ESC followed by typed text must reach the surface.

Regression for the vim "ESC then ':wq!' freezes / keys go unresponsive mid-string"
bug. The host re-encode parser (Sources/GhosttyPaneSurfaceProvider.swift
`sendPeerInputBytes` -> `trailingIncompleteEscape`) used to mis-classify an ESC
followed by a non-CSI/OSC/SS3 byte (e.g. ESC ':') as an *incomplete* escape head
and strand the whole run in `peerPendingInputTail` until 32 bytes accumulated —
so a short ESC-prefixed string was swallowed and only flushed in a late burst,
while self-contained arrow-key CSI sequences kept working.

This drives the exact host path via the DEBUG `debug.peer.inject_input` socket
command (no live peer server needed) and asserts on disk, not on the screen:
run `cat > <file>` so the host writes its stdin to a file, inject
`ESC + MARKER + Enter` through the peer path, send Ctrl-D, and assert the file
contains MARKER. Before the fix the ESC-prefixed bytes strand in
`peerPendingInputTail` and never reach cat, so the file stays empty.

Why cat (not vim): cat is in canonical/cooked mode, so a bare ESC byte is passed
through literally with no mode/alt-screen/readline ambiguity — readiness (file
created by the shell redirect) and the assertion (file contents) are both
deterministic file-on-disk facts. The standard forbids absorbing timing races
with retries, and a TUI-readiness gate (e.g. matching "~") races the lingering
shell prompt. VM contract: the app under test and this script run as the same
user, so the /tmp file the host's `cat` writes is readable here.
"""
import glob
import os
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


def _tail(text: str, n: int = 12) -> str:
    return "\n".join(text.splitlines()[-n:])


def main() -> int:
    token = secrets.token_hex(4)
    marker = f"PEERFIX_{token}"
    testfile = f"/tmp/tm_peer_esc_{os.getpid()}_{token}.txt"

    def file_text():
        try:
            with open(testfile, "rb") as f:
                return f.read().decode("latin-1")
        except FileNotFoundError:
            return None

    try:
        with termmesh() as c:
            sid = c.new_surface(panel_type="terminal")
            c.focus_surface(sid)

            # Shell must be live before we drive it: wait for the prompt to render,
            # then confirm the peer input path delivers plain printables by echoing
            # a unique marker (no ESC — works even on the buggy build).
            if not _wait(lambda: c.read_terminal_text(sid).strip() != "", timeout_s=10):
                raise termmeshError(f"surface {sid} shell prompt never rendered")
            ready = f"TMREADY_{token}"
            c.inject_peer_input(sid, f"echo {ready}\r".encode())
            if not _wait(lambda: ready in c.read_terminal_text(sid), timeout_s=8):
                raise termmeshError(
                    f"peer-injected 'echo {ready}' never echoed — plain printable "
                    f"delivery broken (not the ESC bug). screen:\n{_tail(c.read_terminal_text(sid))}"
                )

            # Start `cat > file`: the host writes its stdin to disk. The shell
            # creates the file when it opens the redirect, so file existence is a
            # deterministic "cat is ready" signal — no TUI/screen scraping.
            c.inject_peer_input(sid, f"cat > {testfile}\r".encode())
            if not _wait(lambda: os.path.exists(testfile), timeout_s=8):
                raise termmeshError(
                    f"`cat > {testfile}` redirect did not create the file (setup "
                    f"failed). screen:\n{_tail(c.read_terminal_text(sid))}"
                )

            # THE REGRESSION: ESC then MARKER then Enter, as one peer Input frame
            # (bytes 1b ... 0d). Before the fix the leading ESC strands the whole
            # run in peerPendingInputTail and cat receives nothing.
            c.inject_peer_input(sid, b"\x1b" + marker.encode() + b"\r")
            # Ctrl-D (0x04): EOF so cat flushes its stdio buffer to the file and exits.
            c.inject_peer_input(sid, b"\x04")

            if not _wait(lambda: marker in (file_text() or ""), timeout_s=10):
                raise termmeshError(
                    f"ESC+{marker!r} did not reach the host surface: {testfile} never "
                    f"received {marker!r} (regression — host stranded ESC-prefixed "
                    f"input). file={file_text()!r} screen:\n{_tail(c.read_terminal_text(sid))}"
                )

            try:
                c.close_surface(sid)
            except termmeshError:
                pass

        print("PASS: peer-injected ESC + text reaches the host surface (cat wrote it to disk)")
        return 0
    finally:
        # Best-effort cleanup so the runner's 3 retries (fresh pid/token each) do
        # not orphan /tmp files; also sweep stale leftovers from earlier crashed
        # runs (older than 5 min, so a concurrent run is never disturbed).
        try:
            os.remove(testfile)
        except FileNotFoundError:
            pass
        for stale in glob.glob("/tmp/tm_peer_esc_*.txt"):
            try:
                if time.time() - os.path.getmtime(stale) > 300:
                    os.remove(stale)
            except OSError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
