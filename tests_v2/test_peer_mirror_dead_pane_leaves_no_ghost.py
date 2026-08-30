#!/usr/bin/env python3
"""A mirrored pane whose relay ended must be CLOSED, not merely unmapped.

The reconcile sweep drops mirror mappings whose pane is gone. Widening it to
also drop mappings whose relay ended is only half a fix: unmapping is enough
when the PANEL is gone too, but a panel that still exists loses both handles
anything has on it — B3's stale-close loop iterates the map, and B3b iterates
the queued stale panels. Miss both and the next push reattaches the surface as
a second tab while the first survives as a ghost holding a dead relay helper
process open. That is the v0.159 leak, re-entered through the sweep meant to
prevent it.

The assertion is a count the ghost cannot hide from: the mirror workspace's
surface count must equal the host's leaf count. A respawn alone keeps both at
N; a ghost puts the workspace at N+1 while the mirror still reports N leaves.

Loopback: the app mirrors its own workspace through the in-app peer server.
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


def _panes_by_surface(mirror: dict) -> dict:
    return {p["surface_id"]: p for p in (mirror.get("panes") or [])}


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

        def _all_live(expected: int) -> bool:
            panes = c.peer_mirror_status().get("panes") or []
            return len(panes) == expected and all(
                p.get("relay_liveness") == "live" for p in panes
            )

        if not _wait(lambda: _all_live(base), timeout_s=90):
            raise termmeshError(
                f"live mirror never reached {base} live panes: {c.peer_mirror_status()!r}"
            )
        mirror = c.peer_mirror_status()
        ws_b = mirror.get("workspace_id")
        if not ws_b:
            raise termmeshError(f"mirror reports no workspace id: {mirror!r}")
        before = _panes_by_surface(mirror)
        if len(c.list_surfaces(ws_b)) != base:
            raise termmeshError(
                f"mirror workspace started with {len(c.list_surfaces(ws_b))} surfaces, "
                f"expected {base}"
            )

        # ── kill one pane's relay, leaving its pane session and its PANEL in
        #    place. This is the state the sweep now acts on.
        victim = sorted(before)[0]
        ended = c.peer_mirror_end_pane_relay(victim)
        if not ended.get("ok"):
            raise termmeshError(f"end pane relay refused: {ended!r}")
        if not _wait(
            lambda: (_panes_by_surface(c.peer_mirror_status()).get(victim) or {}).get(
                "relay_liveness"
            )
            == "ended",
            timeout_s=30,
        ):
            raise termmeshError(
                f"pane {victim} relay never reported ended: {c.peer_mirror_status()!r}"
            )

        # ── make the host push a layout. The sweep runs at the top of the
        #    reconcile that push triggers, which is where the mapping is
        #    dropped and the panel must be queued to close.
        c.select_workspace(ws_a)
        time.sleep(0.5)
        c.new_split("down")
        target = base + 1

        if not _wait(lambda: _all_live(target), timeout_s=90):
            raise termmeshError(
                f"mirror never reached {target} live panes after the host split: "
                f"{c.peer_mirror_status()!r}"
            )
        mirror = c.peer_mirror_status()
        if mirror.get("leaf_count") != target:
            raise termmeshError(f"mirror leaf count is not {target}: {mirror!r}")

        # The ghost check. `leaf_count` counts MAPPINGS, so an unmapped-but-open
        # panel is invisible to it; the workspace's own surface count is not.
        actual = len(c.list_surfaces(ws_b))
        if actual != target:
            raise termmeshError(
                f"mirror workspace holds {actual} surfaces for {target} mirrored leaves "
                "— an unmapped panel was left open (ghost tab + leaked relay helper)"
            )

        after = _panes_by_surface(mirror)
        if after[victim]["panel_id"] == before[victim]["panel_id"]:
            raise termmeshError(
                f"the dead pane kept its panel — it was never respawned: {after[victim]!r}"
            )
        for surface, row in before.items():
            if surface == victim:
                continue
            if after[surface]["panel_id"] != row["panel_id"]:
                raise termmeshError(
                    f"live pane {surface} was rebuilt by the sweep: "
                    f"{row['panel_id']} → {after[surface]['panel_id']}"
                )

        print("PASS: a mirrored pane whose relay ended is closed, not orphaned")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
