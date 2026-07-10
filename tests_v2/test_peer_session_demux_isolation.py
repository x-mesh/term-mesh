#!/usr/bin/env python3
"""P1 narrow session sharing: a workspace's panes share ONE peer session, so a
single receive loop must de-multiplex host PtyData to the right pane by
surface_id — without stealing or dropping a sibling's bytes, and without
mis-routing a detached pane's late bytes to a survivor.

Before P1 each pane opened its own PeerSession + handshake. P1 reuses the
workspace subscription session and fans its PtyData out through
`PeerSessionDemux` (swift/PeerProto/Sources/PeerProto/PeerSessionDemux.swift,
routed from the subscription loop in PeerRelayWorkspaceWindowController). A
naive "each pane filters receiveNextMessage() by surface_id" on a shared
session would be wrong twice: pane A would *consume and drop* pane B's frames
(destructive read), and any misrouting would paint B's output into A's pane.

This drives the exact demux the shared path uses via the DEBUG
`debug.peer.demux_probe` socket command (no live 2-node peer session needed).
The probe registers two surfaces (A, B), interleaves their PtyData through the
single router, detaches B, then routes one more frame to each and asserts:

  1. Isolation      — A received only A's bytes, B only B's (no cross-talk).
  2. Order          — bytes arrive in send order per surface.
  3. Continuity     — A kept receiving (a3) after B detached (residual pane
                      stream survives a sibling close).
  4. Detach-drop    — B's post-detach frame ("bX") was dropped, never
                      delivered to A (nor resurrected on B).

This is the client-side complement to the host-side ESC / bracketed-paste
regressions; together they cover both directions of the shared-session path.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def main() -> int:
    with termmesh() as c:
        probe = c.peer_demux_probe()
        a = probe.get("a")
        b = probe.get("b")
        a_count = probe.get("a_count")
        b_count = probe.get("b_count")

        # 1+2. Isolation + order: each surface sees exactly its own bytes, in
        # send order. A's third frame (a3) is sent AFTER B detached.
        if a != "a1a2a3":
            raise termmeshError(
                f"surface A stream wrong: expected 'a1a2a3', got {a!r} "
                f"(cross-talk, dropped, or reordered frames). full probe={probe!r}"
            )
        if b != "b1b2":
            raise termmeshError(
                f"surface B stream wrong: expected 'b1b2', got {b!r}. full probe={probe!r}"
            )

        # 3. Continuity: A kept receiving after B detached.
        if "a3" not in (a or ""):
            raise termmeshError(
                f"surface A stopped after B detached — residual pane stream did "
                f"not survive a sibling close. a={a!r}"
            )

        # 4. Detach-drop: B's post-detach frame must be gone everywhere.
        if "bX" in (a or "") or "bX" in (b or ""):
            raise termmeshError(
                f"post-detach frame 'bX' leaked (a={a!r} b={b!r}) — a detached "
                f"surface's late bytes must be dropped, not mis-routed."
            )

        # Cross-contamination guard (belt-and-suspenders vs. exact match above).
        if "b" in (a or "") or "a" in (b or ""):
            raise termmeshError(
                f"cross-surface contamination: a={a!r} b={b!r}"
            )

        if a_count != 3 or b_count != 2:
            raise termmeshError(
                f"chunk counts wrong: a_count={a_count} (want 3), "
                f"b_count={b_count} (want 2). full probe={probe!r}"
            )

    print("PASS: PeerSessionDemux isolates per-surface PtyData, survives a "
          "sibling detach, and drops a detached surface's late frames")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
