#!/usr/bin/env python3
"""P4 attach-time replay: `GhosttyPaneSurfaceProvider.attach()` prefers the
per-surface `PtyTapHub` ring buffer (raw PTY bytes, ANSI/style preserved)
over the plain-text `readPaneSnapshot` fallback -- but only when the buffer
is certifiably the surface's *complete* output history (non-empty, never
evicted anything to stay under the 64KB cap). A long-lived pane can outlive
the cap; replaying a buffer that already dropped its oldest bytes would risk
starting mid-escape-sequence, so that case must fall back to the coherent
(if plain-text) snapshot instead.

There is no live 2-node peer session in this test environment, so this
drives the exact decision via the DEBUG `debug.peer.replay_probe` socket
command (Sources/GhosttyPaneSurfaceProvider.swift `debugReplayProbe`, mirrors
`attach()`'s own hub lookup + `PtyTapHub.replaySnapshot()` call). The first
probe call against a surface arms it (creates the hub, wires the real PTY
tap callback); a later call reports the live mode/bytes/chunks/bytes_text.

Covers:
  1. Fresh surface + small ANSI-colored output -> mode "buffer", and the
     replayed bytes genuinely contain both the marker text and the raw
     ANSI escape (the actual style-preservation this phase adds -- a
     mode flag alone wouldn't catch a chunk-ordering/loss bug).
  2. Boundary: mass output well past the 64KB cap -> at least one eviction
     -> falls back to mode "snapshot".
  3. Fresh surface + small *plain* output (no escape sequences at all) ->
     mode "buffer" still holds -- the decision is about fill state, not
     content shape.
  4. Unknown surface_id -> {"ok": False, "error": "unknown_surface"}, not an
     RPC-level exception (mirrors test_peer_read_grid.py's contract).
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


def main() -> int:
    with termmesh() as c:
        # --- 1. Fresh surface + small ANSI-colored output -> mode=buffer,
        #        content (marker + raw escape) intact in the replay bytes.
        token1 = secrets.token_hex(4)
        marker1 = f"REPLAYCHK_{token1}"
        sid1 = c.new_surface(panel_type="terminal")
        c.focus_surface(sid1)
        if not _wait(lambda: c.read_terminal_text(sid1).strip() != "", timeout_s=10):
            raise termmeshError(f"surface {sid1} shell prompt never rendered")

        # Arm: creates the PtyTapHub + registers the real PTY tap callback.
        # Nothing has been produced yet, so this call's own result isn't
        # asserted -- it exists purely to arm the hub before output flows.
        armed1 = c.replay_probe(sid1)
        if armed1.get("ok") is not True:
            raise termmeshError(f"replay_probe failed to arm surface {sid1}: {armed1!r}")

        c.send_surface(sid1, f"printf '\\033[31m{marker1}\\033[0m\\n'\r")
        if not _wait(lambda: marker1 in c.read_terminal_text(sid1), timeout_s=8):
            raise termmeshError(
                f"marker {marker1!r} never echoed to the surface. "
                f"screen:\n{c.read_terminal_text(sid1)}"
            )
        # The render wait above can match the *typed command's echo* (which
        # carries the marker as literal backslash-033 text) before the shell
        # has executed printf. Poll the probe itself until the raw ESC byte
        # from printf's OUTPUT lands in the ring buffer — only then are the
        # style-preservation asserts meaningful. A timeout here means the
        # buffer genuinely lost the escape (real P4 failure, not a race).
        if not _wait(
            lambda: "\x1b[31m" in str(c.replay_probe(sid1).get("bytes_text") or ""),
            timeout_s=8,
        ):
            pass  # fall through — the asserts below produce the diagnostic

        probe1 = c.replay_probe(sid1)
        if probe1.get("ok") is not True:
            raise termmeshError(f"replay_probe on a live surface returned ok!=True: {probe1!r}")
        if probe1.get("mode") != "buffer":
            raise termmeshError(
                f"fresh surface with small output should replay from the ring "
                f"buffer, got mode={probe1.get('mode')!r} (full={probe1!r})"
            )
        text1 = str(probe1.get("bytes_text") or "")
        if marker1 not in text1:
            raise termmeshError(
                f"mode=buffer but marker {marker1!r} is missing from the "
                f"replayed bytes -- content did not survive the ring buffer "
                f"intact. bytes_text:\n{text1!r}"
            )
        if "\x1b[31m" not in text1:
            raise termmeshError(
                f"replay buffer lost the raw ANSI color escape -- P4's whole "
                f"point (style-preserving replay) is broken. bytes_text:\n{text1!r}"
            )

        try:
            c.close_surface(sid1)
        except termmeshError:
            pass

        # --- 2. Boundary: mass output well past the 64KB replay cap forces
        #        at least one eviction -> falls back to mode=snapshot.
        sid2 = c.new_surface(panel_type="terminal")
        c.focus_surface(sid2)
        if not _wait(lambda: c.read_terminal_text(sid2).strip() != "", timeout_s=10):
            raise termmeshError(f"surface {sid2} shell prompt never rendered")

        armed2 = c.replay_probe(sid2)
        if armed2.get("ok") is not True:
            raise termmeshError(f"replay_probe failed to arm surface {sid2}: {armed2!r}")

        done_token = secrets.token_hex(4)
        done_marker = f"REPLAYDONE_{done_token}"
        # 200000 bytes of "y\n" repeats is ~3x the 64KB replay cap -- comfortably
        # forces multiple evictions regardless of how Ghostty batches PTY reads.
        c.send_surface(sid2, f"yes | head -c 200000; echo {done_marker}\r")
        if not _wait(lambda: done_marker in c.read_terminal_text(sid2), timeout_s=20):
            raise termmeshError(
                f"mass-output burst never completed. screen:\n{c.read_terminal_text(sid2)}"
            )

        probe2 = c.replay_probe(sid2)
        if probe2.get("ok") is not True:
            raise termmeshError(f"replay_probe on a live surface returned ok!=True: {probe2!r}")
        if probe2.get("mode") != "snapshot":
            raise termmeshError(
                f"surface whose output exceeded the replay cap should fall "
                f"back to mode=snapshot, got mode={probe2.get('mode')!r} "
                f"(full={probe2!r})"
            )

        try:
            c.close_surface(sid2)
        except termmeshError:
            pass

        # --- 3. Fresh surface + small *plain* (non-ANSI) output -> mode=buffer
        #        still holds -- the decision is about fill state, not content.
        token3 = secrets.token_hex(4)
        marker3 = f"REPLAYPLAIN_{token3}"
        sid3 = c.new_surface(panel_type="terminal")
        c.focus_surface(sid3)
        if not _wait(lambda: c.read_terminal_text(sid3).strip() != "", timeout_s=10):
            raise termmeshError(f"surface {sid3} shell prompt never rendered")

        armed3 = c.replay_probe(sid3)
        if armed3.get("ok") is not True:
            raise termmeshError(f"replay_probe failed to arm surface {sid3}: {armed3!r}")

        c.send_surface(sid3, f"echo {marker3}\r")
        if not _wait(lambda: marker3 in c.read_terminal_text(sid3), timeout_s=8):
            raise termmeshError(
                f"marker {marker3!r} never echoed to the surface. "
                f"screen:\n{c.read_terminal_text(sid3)}"
            )

        probe3 = c.replay_probe(sid3)
        if probe3.get("ok") is not True:
            raise termmeshError(f"replay_probe on a live surface returned ok!=True: {probe3!r}")
        if probe3.get("mode") != "buffer":
            raise termmeshError(
                f"fresh surface with small plain-text output should replay "
                f"from the ring buffer, got mode={probe3.get('mode')!r} "
                f"(full={probe3!r})"
            )

        # --- 4. Unknown surface_id -> ok:false, not an exception.
        bogus = "00000000-0000-0000-0000-000000000000"
        missing = c.replay_probe(bogus)
        if missing.get("ok") is not False:
            raise termmeshError(
                f"replay_probe on a nonexistent surface_id should return "
                f"ok:false, got: {missing!r}"
            )
        if missing.get("error") != "unknown_surface":
            raise termmeshError(
                f"replay_probe unknown-surface error mismatch: expected "
                f"'unknown_surface', got {missing.get('error')!r} (full={missing!r})"
            )

        try:
            c.close_surface(sid3)
        except termmeshError:
            pass

    print(
        "PASS: debug.peer.replay_probe confirms attach()'s buffer-vs-snapshot "
        "decision -- fresh/small output (ANSI or plain) replays from the ring "
        "buffer with styling intact, cap-exceeding output falls back to the "
        "plain-text snapshot, and an unknown surface reports ok:false"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
