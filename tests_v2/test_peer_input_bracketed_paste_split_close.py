#!/usr/bin/env python3
"""Peer-relay host input: a bracketed-paste close marker split across input
frames must still close the paste and deliver the body cleanly.

Regression for the host re-encode parser (Sources/GhosttyPaneSurfaceProvider.swift
`absorbPasteContinuation`). While a bracketed paste is open, each input frame is
funneled through `absorbPasteContinuation`, which searches for the 6-byte close
marker `\\e[201~` *within the current frame only* (`while j + 5 < arr.count`).
The relay binary reads stdin in 1024-byte chunks, so a paste whose `\\e[201~`
lands on a chunk boundary arrives split — e.g. `…\\e[20` in one frame and `1~…`
in the next. The buggy version appended the partial marker to the paste body
verbatim, the paste never closed, and subsequent input was swallowed into the
accumulator until the idle timeout — so the body (and any following keystrokes)
never reached the surface, or arrived with literal `\\e[201~` bytes in it.

The fix defers a trailing incomplete ESC sequence into `peerPendingInputTail`
(prepended on the next frame), mirroring the FIX B / UTF-8 tail deferral, so the
split marker reassembles and the paste closes.

Drives the exact host path via the DEBUG `debug.peer.inject_input` socket command
(no live peer server). Asserts on disk via `cat > <file>`: the body marker must
land in the file, and the literal close-marker bytes must NOT.
"""
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
    marker = f"PASTEFIX_{token}"
    testfile = f"/tmp/tm_peer_paste_{os.getpid()}_{token}.txt"

    def file_bytes():
        try:
            with open(testfile, "rb") as f:
                return f.read()
        except FileNotFoundError:
            return None

    try:
        with termmesh() as c:
            sid = c.new_surface(panel_type="terminal")
            c.focus_surface(sid)

            if not _wait(lambda: c.read_terminal_text(sid).strip() != "", timeout_s=10):
                raise termmeshError(f"surface {sid} shell prompt never rendered")

            # Sanity: plain printable delivery works on any build.
            ready = f"TMREADY_{token}"
            c.inject_peer_input(sid, f"echo {ready}\r".encode())
            if not _wait(lambda: ready in c.read_terminal_text(sid), timeout_s=8):
                raise termmeshError(
                    "peer-injected echo never appeared — plain delivery broken "
                    f"(not the paste bug). screen:\n{_tail(c.read_terminal_text(sid))}"
                )

            # `cat > file`: the surface's shell writes its stdin to disk verbatim,
            # so the assertion is a deterministic file fact, not a screen scrape.
            c.inject_peer_input(sid, f"cat > {testfile}\r".encode())
            # Confirm cat is actually consuming stdin before pasting: write a
            # sentinel line and wait for it to land in the file. Otherwise the
            # paste can race cat startup and hit the shell prompt instead.
            sentinel = f"SENT_{token}"
            if not _wait(lambda: True, timeout_s=0.5):
                pass
            c.inject_peer_input(sid, f"{sentinel}\r".encode())
            if not _wait(lambda: sentinel.encode() in (file_bytes() or b""), timeout_s=8):
                raise termmeshError(
                    "cat never consumed the sentinel — shell/cat not ready "
                    f"(test setup, not the paste bug). screen:\n{_tail(c.read_terminal_text(sid))}"
                )

            # Bracketed paste with the close marker split across frames.
            # Frame 1: open marker + body (no close).
            # Frame 2: first 4 bytes of the close marker (\e [ 2 0).
            # Frame 3: remaining 2 bytes (1 ~) + trailing newline so cat flushes a line.
            c.inject_peer_input(sid, b"\x1b[200~" + marker.encode())
            time.sleep(0.15)
            c.inject_peer_input(sid, b"\x1b[20")        # partial close marker
            time.sleep(0.15)
            c.inject_peer_input(sid, b"1~")             # rest of close marker
            time.sleep(0.15)
            c.inject_peer_input(sid, b"\r")             # Return -> tty NL so cat flushes the line
            time.sleep(0.2)
            c.inject_peer_input(sid, b"\x04")           # Ctrl-D: cat EOF -> flush+exit

            if not _wait(lambda: marker.encode() in (file_bytes() or b""), timeout_s=8):
                raise termmeshError(
                    f"paste body {marker!r} never reached cat — swallowed by the open "
                    f"accumulator (the split-close-marker bug). file={file_bytes()!r} "
                    f"screen:\n{_tail(c.read_terminal_text(sid))}"
                )

            data = file_bytes() or b""
            text = data.decode("latin-1")
            if b"\x1b[201~" in data or b"\x1b[200~" in data:
                raise termmeshError(f"literal bracketed-paste markers leaked into body: {data!r}")

            print(f"PASS: split bracketed-paste close marker reassembled; body delivered cleanly ({marker})")
            return 0
    finally:
        try:
            os.remove(testfile)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
