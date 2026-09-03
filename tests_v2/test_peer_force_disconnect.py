#!/usr/bin/env python3
"""Force Disconnect: close every connection opened from a peer host, and
leave the sidebar row in a state the user can act on.

Two bugs motivate this, both of which needed an app restart to escape:

  1. Disconnect is gated on holding a sidebar lease, but
     `RemoteHostStore.syncFromCoordinator` re-promotes a row to `.connected`
     whenever a pane or mirror still holds its own lease. With the lease gone
     and a pane alive the row offered neither Connect (not saved/failed), nor
     Disconnect (no lease), nor Cancel (not connecting) — no action at all.

  2. Force Disconnect used to leave exactly one pane behind. While a live
     mirror owns the workspace, `Workspace.mirrorForwardsLocalActions` turns
     every local close into a forwardClose to the host and returns false, and
     the host never pushes a layout dropping the last surface in a workspace.
     Mirrors are now closed before panes so the forwarding predicate is off
     by the time any pane is asked to close.

No live 2-node peer session exists here, so this drives the flow loopback:
`debug.peer.open_remote_pane` (no sock_path) brings up the app's own in-app
peer server and attaches one of this instance's own surfaces. The resulting
connections register in `PeerClientCoordinator.activeConnections()`, which is
what materializes the ad-hoc host row that `peer.host.*` then acts on — the
same production store the sidebar renders.

Covers:
  1. Panes opened from a host surface as a host row in `peer.host.list`.
  2. Force Disconnect reports `closed` == the number of open connections.
  3. Every pane session is gone and the host lease count returns to 0 —
     no survivor, and no leaked tunnel.
  4. The row lands on `saved` with no sidebar lease, i.e. Connect is
     reachable again rather than the dead end described above.
  5. An unknown host handle is a clean `not_found`, not a crash or a
     silent no-op on some other host.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

PANES_TO_OPEN = 3


def _wait(predicate, timeout_s: float = 20.0, interval_s: float = 0.2) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            if predicate():
                return True
        except termmeshError:
            # Early polls can race the in-app peer server's bring-up; a
            # transient RPC timeout means "not ready yet", not a failure.
            pass
        time.sleep(interval_s)
    return False


def _live_pane_count(c: termmesh) -> int:
    sessions = c.peer_pane_status().get("pane_sessions") or []
    return sum(1 for s in sessions if not s.get("torn_down"))


def main() -> int:
    with termmesh() as c:
        sid = c.new_surface(panel_type="terminal")
        c.focus_surface(sid)
        if not _wait(lambda: c.read_terminal_text(sid).strip() != "", timeout_s=10):
            raise termmeshError(f"surface {sid} shell prompt never rendered")

        # --- baseline
        status = c.peer_pane_status()
        if status.get("pane_sessions"):
            raise termmeshError(f"expected no pane sessions at baseline, got {status!r}")
        if status.get("lease_count", 0) != 0:
            raise termmeshError(f"expected 0 leases at baseline, got {status!r}")

        # --- 1. open several loopback remote panes
        for n in range(PANES_TO_OPEN):
            kicked = c.peer_open_remote_pane()
            if not kicked.get("started"):
                raise termmeshError(f"open_remote_pane {n} did not start: {kicked!r}")
            if not _wait(lambda n=n: _live_pane_count(c) == n + 1, timeout_s=25):
                raise termmeshError(
                    f"pane {n + 1} never landed; status={c.peer_pane_status()!r}"
                )

        opened = _live_pane_count(c)
        if opened != PANES_TO_OPEN:
            raise termmeshError(f"expected {PANES_TO_OPEN} panes, got {opened}")

        # --- 2. the panes materialized a host row
        hosts = c.peer_host_list()
        if not hosts:
            raise termmeshError("peer.host.list is empty after opening panes")
        connected = [h for h in hosts if h.get("state") == "connected"]
        if len(connected) != 1:
            raise termmeshError(
                f"expected exactly 1 connected host, got {[h.get('id') for h in connected]}"
            )
        host_id = connected[0]["id"]

        # The row is `connected` while holding no sidebar lease — the very
        # combination that used to hide every action. Force Disconnect is the
        # way out, so assert the precondition actually holds here.
        if connected[0].get("has_sidebar_lease"):
            raise termmeshError(
                "expected a pane-only host row to hold no sidebar lease, "
                f"got {connected[0]!r}"
            )

        # --- 3. force disconnect is gated because it destroys local mirrors
        # and panes, unlike the transport-only disconnect command.
        try:
            c.peer_host_force_disconnect(host_id)
        except termmeshError as exc:
            if "confirmation_required" not in str(exc):
                raise termmeshError(f"expected confirmation_required, got {exc}")
        else:
            raise termmeshError("force_disconnect without confirm unexpectedly succeeded")
        if _live_pane_count(c) != opened:
            raise termmeshError("unconfirmed force_disconnect changed pane state")

        result = c.peer_host_force_disconnect(host_id, confirm=True)
        if not result.get("ok"):
            raise termmeshError(f"force_disconnect failed: {result!r}")
        if result.get("closed") != opened:
            raise termmeshError(
                f"expected closed={opened}, got {result.get('closed')} ({result!r})"
            )
        counts = result.get("closed_by_type") or {}
        expected_counts = {
            "panes": opened, "mirrors": 0, "relay_windows": 0, "other": 0
        }
        if counts != expected_counts:
            raise termmeshError(f"unexpected typed close counts: {counts!r}")
        if not result.get("destructive") or "mirrors" not in result.get("warning", ""):
            raise termmeshError(f"destructive warning missing: {result!r}")

        if not _wait(lambda: _live_pane_count(c) == 0, timeout_s=20):
            raise termmeshError(
                f"panes survived force disconnect: {c.peer_pane_status()!r}"
            )
        # The lease must drop too: a live lease with no pane is a leaked tunnel.
        if not _wait(lambda: c.peer_pane_status().get("lease_count", -1) == 0, timeout_s=20):
            raise termmeshError(
                f"host lease leaked after force disconnect: {c.peer_pane_status()!r}"
            )

        # --- 4. the row is actionable again
        after = [h for h in c.peer_host_list() if h.get("id") == host_id]
        if after:
            state = after[0].get("state")
            if state not in ("saved", "failed"):
                raise termmeshError(
                    f"expected host row back to saved/failed, got {state!r} ({after[0]!r})"
                )
            if after[0].get("has_sidebar_lease"):
                raise termmeshError(f"sidebar lease survived force disconnect: {after[0]!r}")
        # An ad-hoc row with no remaining connection may be dropped entirely,
        # which is equally fine — what must not happen is it staying
        # `connected` with nothing behind it.

        # --- 5. unknown host is a clean error
        try:
            c.peer_host_force_disconnect("definitely-not-a-host", confirm=True)
        except termmeshError as exc:
            if "not_found" not in str(exc):
                raise termmeshError(f"expected not_found for unknown host, got {exc}")
        else:
            raise termmeshError("force_disconnect on an unknown host unexpectedly succeeded")

        print(f"PASS: force disconnect closed {opened} panes, lease released, row actionable")
        return 0


if __name__ == "__main__":
    sys.exit(main())
