#!/usr/bin/env python3
"""A layout push that removes a pane must be named by the host AND by the
viewer, including across a mirror reconnect.

A removal is the only layout change that costs an attached viewer a pane — the
pane and its scrollback go with it. The viewer's "Remote pane closed" line is
also what it logs when the user closes that same pane, and the host said
nothing at all, which is how a real pane-loss incident became unanswerable
from logs.

Three claims, one per phase:

  1. host: a push that drops a leaf names it; a push that ADDS one is silent,
     because splits are recoverable and a line per split is noise.
  2. viewer: the same drop is named locally before the panes are closed.
  3. viewer across a reconnect: the reconnect has to clear
     `lastAppliedLayout` to force the full reconcile, and that is the baseline
     the drop diff reads — so the incident's own path was the one path that
     could not say what the host dropped. It must not be.

Loopback: the app mirrors its own workspace through the in-app peer server, so
the host half and the viewer half are both observable from one socket.
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


def main() -> int:
    with termmesh() as c:
        surfaces = c.list_surfaces()
        sid = next((s for _, s, focused in surfaces if focused), None)
        sid = sid or (surfaces[0][1] if surfaces else None)
        if not sid:
            raise termmeshError("fresh workspace has no seed surface")
        c.focus_surface(sid)
        if not _wait(lambda: c.read_terminal_text(sid).strip() != "", timeout_s=15):
            raise termmeshError("seed surface never rendered")
        workspaces = c.list_workspaces()
        ws_a = next(w[1] for w in workspaces if w[3])
        c.new_split("right")
        time.sleep(1.0)
        base = len(c.list_panes())
        if base < 2:
            raise termmeshError(f"expected >=2 host panes after seed split, got {base}")

        kicked = c._call("debug.peer.open_workspace_mirror", {"live": True})
        if not (kicked or {}).get("started"):
            raise termmeshError(f"live mirror kick failed: {kicked!r}")

        def _mirror() -> dict:
            return c.peer_mirror_status()

        def _all_live(expected: int) -> bool:
            panes = _mirror().get("panes") or []
            return len(panes) == expected and all(
                p.get("relay_liveness") == "live" for p in panes
            )

        if not _wait(lambda: _all_live(base), timeout_s=90):
            raise termmeshError(
                f"live mirror never reached {base} live panes: {_mirror()!r}"
            )
        ws_b = _mirror().get("workspace_id")
        if not ws_b:
            raise termmeshError(f"mirror reports no workspace id: {_mirror()!r}")

        # ── 1a. a push that ADDS a leaf must stay silent on the host.
        host_before = c.peer_host_status().get("dropping_broadcasts", 0)
        c.select_workspace(ws_a)
        time.sleep(0.5)
        c.new_split("down")
        grown = base + 1
        if not _wait(lambda: _all_live(grown), timeout_s=90):
            raise termmeshError(f"mirror did not follow the host split: {_mirror()!r}")
        host_after = c.peer_host_status().get("dropping_broadcasts", 0)
        if host_after != host_before:
            raise termmeshError(
                "a growing layout was reported as a removal — splits are "
                f"recoverable and must stay silent: {c.peer_host_status()!r}"
            )

        # ── 1b/2. close a host pane: the host names it, and so does the viewer.
        c.select_workspace(ws_a)
        time.sleep(0.5)
        panes = c.list_panes()
        if len(panes) != grown:
            raise termmeshError(f"host lost track of its panes: {panes!r}")
        c.close_surface()
        shrunk = grown - 1

        if not _wait(
            lambda: c.peer_host_status().get("dropping_broadcasts", 0) > host_before,
            timeout_s=30,
        ):
            raise termmeshError(
                f"the host never named the pane it dropped: {c.peer_host_status()!r}"
            )
        host_status = c.peer_host_status()
        if len(host_status.get("last_dropped_leaves") or []) != 1:
            raise termmeshError(
                f"host named the wrong number of dropped leaves: {host_status!r}"
            )

        if not _wait(
            lambda: _mirror().get("dropped_pane_reports", 0) > 0
            and _mirror().get("leaf_count") == shrunk,
            timeout_s=60,
        ):
            raise termmeshError(
                f"the viewer never named the pane the host dropped: {_mirror()!r}"
            )
        if len(_mirror().get("dropped_pane_names") or []) != 1:
            raise termmeshError(
                f"viewer named the wrong number of dropped panes: {_mirror()!r}"
            )

        # ── 3. the drop that arrives WHILE the subscription is down.
        #
        # This is the incident's own shape, and the path the fast reconnect
        # has to clear `lastAppliedLayout` on — so it is the one path with no
        # baseline to diff a removal against. Hold the reconnect down so the
        # host change lands inside the window rather than racing the 2s
        # first-attempt backoff.
        if not _wait(lambda: _all_live(shrunk), timeout_s=90):
            raise termmeshError(f"mirror never settled at {shrunk} live panes: {_mirror()!r}")
        # Counts, not names: every pane here is titled "Terminal", so two drops
        # in a row produce identical name lists and a list comparison cannot
        # tell the second drop from silence.
        reports_before = _mirror().get("dropped_pane_reports", 0)
        baseline_reports_before = _mirror().get("dropped_pane_reports_after_reconnect", 0)

        c.select_workspace(ws_a)
        time.sleep(0.5)
        dropped = c.peer_mirror_drop_subscription(hold_reconnect_s=8)
        if not dropped.get("dropped"):
            raise termmeshError(f"subscription drop refused: {dropped!r}")
        if not _wait(lambda: not _mirror().get("subscription_alive"), timeout_s=20):
            raise termmeshError(f"subscription never went down: {_mirror()!r}")

        # The host loses a pane with nobody listening.
        c.close_surface()
        final = shrunk - 1
        if not _wait(lambda: len(c.list_panes()) == final, timeout_s=20):
            raise termmeshError(f"host did not lose the pane: {c.list_panes()!r}")
        if _mirror().get("dropped_pane_reports", 0) != reports_before:
            raise termmeshError(
                "the viewer saw the drop while its subscription was down — the hold "
                f"did not hold: {_mirror()!r}"
            )

        # Now let it back up. The reconnect's own reconcile is what must name
        # the removal, reading the baseline the resync handed forward.
        if not _wait(
            lambda: _mirror().get("subscription_alive")
            and _mirror().get("leaf_count") == final,
            timeout_s=90,
        ):
            raise termmeshError(f"mirror never reconnected: {_mirror()!r}")
        mirror = _mirror()
        if mirror.get("dropped_pane_reports_after_reconnect", 0) <= baseline_reports_before:
            raise termmeshError(
                "the reconnect's reconcile did not name the pane the host dropped "
                f"while it was down — the baseline was lost: {mirror!r}"
            )
        if len(mirror.get("dropped_pane_names") or []) != 1:
            raise termmeshError(
                f"post-reconnect drop named the wrong count: {mirror!r}"
            )
        if not _wait(lambda: _all_live(final), timeout_s=90):
            raise termmeshError(
                f"mirror never settled at {final} live panes: {_mirror()!r}"
            )

        print("PASS: host and viewer both name a dropped pane, reconnect included")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
