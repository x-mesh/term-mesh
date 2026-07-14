#!/usr/bin/env python3
"""Phase 2B live workspace mirror: a main-window workspace that tracks a
host workspace in BOTH directions — host layout pushes reshape the local
bonsplit tree (reconciler), and local structural actions forward to the
host as WorkspaceControl requests instead of mutating locally.

Loopback: the app mirrors its own FIRST workspace (A) into a new live
mirror workspace (B) via the in-app peer server.

Covers:
  1. Open: live mirror of A (2 leaves after a seed split) → mirror_status
     reports subscription_alive, leaf_count == 2, one shared lease.
  2. Host→mirror: splitting A pushes a layout → B converges to 3 leaves.
  3. Mirror→host: socket-splitting B forwards (B does NOT grow a local
     pane by itself) → A gains a pane → the echo push converges B to 4.
  4. Close forwarding: socket-closing a B pane forwards → both sides
     drop to 3; a surviving B pane still renders (PTY continuity).
  5. Teardown: closing B releases every session, the lease, and the
     mirror controller.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def _wait(predicate, timeout_s: float = 30.0, interval_s: float = 0.3) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def _mirror(c) -> dict:
    try:
        status = c._call("debug.peer.mirror_status", {}) or {}
    except termmeshError:
        return {}
    mirrors = (status.get("status") or {}).get("mirrors") or []
    return mirrors[0] if mirrors else {}


def _pane_status(c) -> dict:
    try:
        return c.peer_pane_status()
    except termmeshError:
        return {}


def main() -> int:
    with termmesh() as c:
        # ── seed workspace A with a split (2 leaves)
        sid = c.new_surface(panel_type="terminal")
        c.focus_surface(sid)
        if not _wait(lambda: c.read_terminal_text(sid).strip() != "", timeout_s=10):
            raise termmeshError("seed surface never rendered")
        workspaces = c.list_workspaces()
        ws_a = next(w[1] for w in workspaces if w[3])  # selected workspace id
        c.new_split("right")
        time.sleep(1.0)
        # Session restore may have left extra panes from earlier runs —
        # assert deltas against this baseline, not absolute counts.
        base_a = len(c.list_panes())
        if base_a < 2:
            raise termmeshError(f"expected >=2 panes in A after seed split, got {base_a}")

        # ── 1. open the live mirror
        kicked = c._call("debug.peer.open_workspace_mirror", {"live": True})
        if not (kicked or {}).get("started"):
            raise termmeshError(f"live mirror kick failed: {kicked!r}")
        if not _wait(lambda: _mirror(c).get("leaf_count") == base_a
                     and _mirror(c).get("subscription_alive"), timeout_s=90):
            raise termmeshError(
                f"live mirror never converged to {base_a} leaves: {_mirror(c)!r}"
            )
        mirror = _mirror(c)
        ws_b = mirror.get("workspace_id")
        if not ws_b:
            raise termmeshError(f"mirror reports no workspace id: {mirror!r}")
        status = _pane_status(c)
        if status.get("lease_count") != 1:
            raise termmeshError(f"expected 1 shared lease, got {status!r}")

        # ── 2. host → mirror: split A, B follows
        c.select_workspace(ws_a)
        time.sleep(0.5)
        c.new_split("down")
        if not _wait(lambda: _mirror(c).get("leaf_count") == base_a + 1, timeout_s=30):
            raise termmeshError(f"mirror did not follow host split: {_mirror(c)!r}")

        # ── 3. mirror → host: split B, forwards to A, echo converges B
        c.select_workspace(ws_b)
        time.sleep(0.5)
        # The socket split MUST fail locally: in mirror mode the request
        # forwards to the host and creates nothing here. A success would
        # mean the gate leaked and B mutated its own layout.
        try:
            c.new_split("right")
            raise termmeshError("mirror-side split created a LOCAL pane (gate leaked)")
        except termmeshError as e:
            if "Failed to create split" not in str(e):
                raise
        # Forwarded split: A must gain a pane…
        def _a_panes() -> int:
            c.select_workspace(ws_a)
            return len(c.list_panes())
        if not _wait(lambda: _a_panes() == base_a + 2, timeout_s=30):
            raise termmeshError(f"host A never gained the forwarded pane: {_a_panes()}")
        # …and the echo push converges B.
        if not _wait(lambda: _mirror(c).get("leaf_count") == base_a + 2, timeout_s=30):
            raise termmeshError(f"mirror did not converge after forwarded split: {_mirror(c)!r}")

        # ── 4. close forwarding: close B's focused pane
        c.select_workspace(ws_b)
        time.sleep(0.5)
        # Close forwards too. (The socket handler reports ok regardless of
        # closePanel's return, so the gate is proven by convergence on
        # BOTH sides below — the host must lose the pane, which can only
        # happen via the forwarded request.)
        c._call("surface.close", {})
        if not _wait(lambda: _mirror(c).get("leaf_count") == base_a + 1, timeout_s=30):
            raise termmeshError(f"mirror did not converge after forwarded close: {_mirror(c)!r}")
        if not _wait(lambda: _a_panes() == base_a + 1, timeout_s=15):
            raise termmeshError(f"host A did not lose the closed pane: {_a_panes()}")
        # PTY continuity: a surviving mirror pane still renders bytes.
        c.select_workspace(ws_b)
        time.sleep(0.5)
        if not _wait(lambda: c.read_terminal_text(None).strip() != "", timeout_s=20):
            raise termmeshError("surviving mirror pane rendered nothing after reconcile")

        # ── 5. teardown: closing B releases sessions + lease + mirror
        c.close_workspace(ws_b)

        def _cleaned() -> bool:
            if _mirror(c):
                return False
            s = _pane_status(c)
            return not (s.get("pane_sessions") or []) and s.get("lease_count", 1) == 0

        if not _wait(_cleaned, timeout_s=20):
            raise termmeshError(
                f"mirror close did not clean up: mirror={_mirror(c)!r} panes={_pane_status(c)!r}"
            )

        print("OK test_peer_workspace_mirror_live")
        return 0


if __name__ == "__main__":
    sys.exit(main())
