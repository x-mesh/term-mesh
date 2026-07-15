#!/usr/bin/env python3
"""Phase 1 remote pane primitive: a remote peer surface hosted as a NORMAL
main-window Bonsplit pane (`Workspace.openRemotePane`), with session
ownership on the panel (`PeerPaneSession`) and per-host lease pooling
(`PeerPaneHostRegistry`).

There is no live 2-node peer session in this test environment, so this
drives the flow loopback: the DEBUG `debug.peer.open_remote_pane` socket
command brings up the app's own in-app peer server and attaches one of
this instance's own surfaces as a remote pane (self-mirror). The relay
plumbing exercised is the production path — PeerRelaySession connect +
handshake + AttachSurface + term-mesh-peer-relay spawned as the pane's
shell — only the network hop (SSH tunnel) is absent.

Covers:
  1. Open: `debug.peer.open_remote_pane` (no sock_path → loopback) lands
     `last_open_result.ok == True`; exactly one pane session and one
     host lease exist; the workspace gained a surface.
  2. The remote pane renders: its terminal text becomes non-empty (the
     mirrored shell's prompt flows host → relay → Ghostty).
  3. Close: closing the remote pane tears the session down — pane
     session list empties AND the host lease count returns to 0 (the
     R2 lease-release contract; a leak here means dangling tunnels).
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def _wait(predicate, timeout_s: float = 15.0, interval_s: float = 0.2) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def main() -> int:
    with termmesh() as c:
        # Focused terminal pane is the split source for openRemotePane.
        sid = c.new_surface(panel_type="terminal")
        c.focus_surface(sid)
        if not _wait(lambda: c.read_terminal_text(sid).strip() != "", timeout_s=10):
            raise termmeshError(f"surface {sid} shell prompt never rendered")

        # --- baseline: no pane sessions, no leases
        status = c.peer_pane_status()
        if status.get("pane_sessions"):
            raise termmeshError(f"expected no pane sessions at baseline, got {status!r}")
        if status.get("lease_count", 0) != 0:
            raise termmeshError(f"expected 0 leases at baseline, got {status!r}")

        # --- 1. open a loopback remote pane
        kicked = c.peer_open_remote_pane()
        if not kicked.get("started"):
            raise termmeshError(f"open_remote_pane did not start: {kicked!r}")

        def _open_result():
            # The first status polls can race the in-app peer server's
            # bring-up (main-thread contention on first boot) — treat a
            # transient RPC timeout as "not ready yet", not a failure.
            try:
                result = c.peer_pane_status().get("last_open_result")
            except termmeshError:
                return None
            return result if isinstance(result, dict) else None

        # Generous budget: the loopback flow rides the in-app Swift peer
        # server, whose first ListSurfaces takes tens of seconds (pane
        # snapshot reads — the C3/C7 slowness, not a pane-primitive
        # cost; the Rust term-meshd host answers in milliseconds).
        if not _wait(lambda: _open_result() is not None, timeout_s=60):
            raise termmeshError("open_remote_pane never reported a result")
        result = _open_result()
        if not result.get("ok"):
            raise termmeshError(f"open_remote_pane failed: {result!r}")
        panel_id = result["panel_id"]

        status = c.peer_pane_status()
        sessions = status.get("pane_sessions") or []
        if len(sessions) != 1:
            raise termmeshError(f"expected exactly 1 pane session, got {status!r}")
        if status.get("lease_count") != 1:
            raise termmeshError(f"expected exactly 1 host lease, got {status!r}")
        if sessions[0].get("torn_down"):
            raise termmeshError(f"fresh pane session reports torn_down: {status!r}")

        # --- 2. the remote pane renders the mirrored shell
        if not _wait(lambda: c.read_terminal_text(panel_id).strip() != "", timeout_s=20):
            raise termmeshError("remote pane never rendered any bytes")

        # --- 3. closing the pane releases session + lease
        c.close_surface(panel_id)

        def _cleaned_up():
            try:
                s = c.peer_pane_status()
            except termmeshError:
                return False
            return not (s.get("pane_sessions") or []) and s.get("lease_count", 1) == 0

        if not _wait(_cleaned_up, timeout_s=15):
            raise termmeshError(
                f"pane close did not release session/lease: {c.peer_pane_status()!r}"
            )

        print("OK test_peer_remote_pane")
        return 0


if __name__ == "__main__":
    sys.exit(main())
