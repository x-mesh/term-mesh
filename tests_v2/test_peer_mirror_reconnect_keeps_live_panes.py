#!/usr/bin/env python3
"""A mirror reconnect must keep the panes whose relay is up, and must decide
that on live transport state rather than on whether the relay ever started.

Two independent recoveries exist and do not know about each other: a pane's
own relay reconnects itself, while the workspace mirror reconnects only its
layout subscription. The pane one routinely finishes first, so a mirror
reconnect that wipes its map unconditionally respawns a helper process and a
Ghostty surface for panes that were already working — and closes the working
ones, losing their scrollback.

Keeping them is only safe if "recovered" is answered correctly, and the
obvious answer is wrong: `relay_startup_state` is written once, when the first
start succeeds, and never again. A pane whose transport died still reports
`started` forever. This test asserts both halves:

  1. subscription dropped, every pane live  → kept 2, respawned 0, and the
     SAME panel ids survive (identity, not just a matching count)
  2. one pane's relay ended, pane session untouched → `relay_startup_state`
     still reads `started` while `relay_liveness` reads `ended`, so a resync
     keyed on the former would keep a dead pane; the resync respawns it

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


def _io_progressed(before: dict, after: dict) -> bool:
    """Require real host-to-viewer delivery, not only a live transport flag."""
    old = before.get("io") or {}
    new = after.get("io") or {}
    return (
        int(new.get("bytes_received") or 0) > int(old.get("bytes_received") or 0)
        and int(new.get("bytes_enqueued") or 0) > int(old.get("bytes_enqueued") or 0)
        and int(new.get("chunks") or 0) > int(old.get("chunks") or 0)
    )


def main() -> int:
    with termmesh() as c:
        # ── seed a 2-leaf host workspace and mirror it
        surfaces = c.list_surfaces()
        sid = next((s for _, s, focused in surfaces if focused), None)
        sid = sid or (surfaces[0][1] if surfaces else None)
        if not sid:
            raise termmeshError("fresh workspace has no seed surface")
        c.focus_surface(sid)
        if not _wait(lambda: c.read_terminal_text(sid).strip() != "", timeout_s=15):
            raise termmeshError("seed surface never rendered")
        c.new_split("right")
        time.sleep(1.0)
        base = len(c.list_panes())
        if base < 2:
            raise termmeshError(f"expected >=2 host panes after seed split, got {base}")

        kicked = c._call("debug.peer.open_workspace_mirror", {"live": True})
        if not (kicked or {}).get("started"):
            raise termmeshError(f"live mirror kick failed: {kicked!r}")
        if not _wait(
            lambda: c.peer_mirror_status().get("leaf_count") == base
            and c.peer_mirror_status().get("subscription_alive"),
            timeout_s=90,
        ):
            raise termmeshError(
                f"live mirror never converged to {base} leaves: {c.peer_mirror_status()!r}"
            )

        # Every pane must actually be live before the first drop, or "kept"
        # would be measuring the wrong starting state.
        def _all_live() -> bool:
            panes = (c.peer_mirror_status().get("panes") or [])
            return len(panes) == base and all(
                p.get("relay_liveness") == "live" for p in panes
            )

        if not _wait(_all_live, timeout_s=60):
            raise termmeshError(
                f"mirrored panes never all reached live: {c.peer_mirror_status()!r}"
            )
        before = _panes_by_surface(c.peer_mirror_status())

        # ── 1. drop ONLY the subscription. Panes are untouched, so the
        #       reconnect must cost nothing.
        dropped = c.peer_mirror_drop_subscription()
        if not dropped.get("dropped"):
            raise termmeshError(f"subscription drop refused: {dropped!r}")

        def _resynced() -> bool:
            m = c.peer_mirror_status()
            return bool(m.get("subscription_alive")) and (
                m.get("resync") or {}
            ).get("kept", 0) > 0

        if not _wait(_resynced, timeout_s=90):
            raise termmeshError(
                f"mirror never resynced after subscription drop: {c.peer_mirror_status()!r}"
            )
        mirror = c.peer_mirror_status()
        resync = mirror.get("resync") or {}
        if resync.get("kept") != base or resync.get("respawned") != 0:
            raise termmeshError(
                f"expected kept={base} respawned=0 for a resync with every pane live, "
                f"got {resync!r}"
            )
        # Identity, not arithmetic: a respawn-then-close cycle also lands on
        # `base` panes, and it is exactly what the change exists to avoid.
        after = _panes_by_surface(mirror)
        if set(after) != set(before):
            raise termmeshError(
                f"kept panes changed surface: before={sorted(before)} after={sorted(after)}"
            )
        for surface, row in before.items():
            if after[surface]["panel_id"] != row["panel_id"]:
                raise termmeshError(
                    f"surface {surface} was respawned despite being live: "
                    f"{row['panel_id']} → {after[surface]['panel_id']}"
                )
        if mirror.get("leaf_count") != base:
            raise termmeshError(f"leaf count drifted after resync: {mirror!r}")

        # A half-alive pane reports every transport/startup flag as healthy
        # while host-to-relay delivery is permanently frozen. Make every
        # remote shell redraw and require its actual counters to advance.
        progress_before = _panes_by_surface(c.peer_mirror_status())
        for surface in sorted(progress_before):
            c.send_surface(
                progress_before[surface]["panel_id"], "printf issue455-progress\n"
            )

        def _all_progressed() -> bool:
            current = _panes_by_surface(c.peer_mirror_status())
            return set(current) == set(progress_before) and all(
                _io_progressed(progress_before[surface], current[surface])
                for surface in progress_before
            )

        if not _wait(_all_progressed, timeout_s=30):
            raise termmeshError(
                "mirror panes stayed transport-live but host output did not advance "
                f"after reconnect: before={progress_before!r} "
                f"after={_panes_by_surface(c.peer_mirror_status())!r}"
            )

        # ── 1b. Drop one pane's OWNED host transport. This is issue #455's
        # exact primary path: panel/helper stay alive, receive gets EOF, the
        # same pane reconnects, and output must resume under a new generation.
        transport_victim = sorted(progress_before)[0]
        transport_before = _panes_by_surface(c.peer_mirror_status())[transport_victim]
        old_generation = int((transport_before.get("io") or {}).get("session_generation") or 0)
        dropped_transport = c.peer_mirror_drop_pane_transport(transport_victim)
        if not dropped_transport.get("ok"):
            raise termmeshError(f"pane transport drop refused: {dropped_transport!r}")

        def _owned_reconnected() -> bool:
            row = _panes_by_surface(c.peer_mirror_status()).get(transport_victim) or {}
            io = row.get("io") or {}
            return (
                row.get("pane_health") == "live"
                and int(io.get("session_generation") or 0) > old_generation
                and io.get("resume_gate_phase") == "idle"
            )

        if not _wait(_owned_reconnected, timeout_s=60):
            raise termmeshError(
                "owned pane transport did not reconnect under a fresh idle generation: "
                f"{_panes_by_surface(c.peer_mirror_status()).get(transport_victim)!r}"
            )
        reconnected_before = _panes_by_surface(c.peer_mirror_status())[transport_victim]
        c.send_surface(reconnected_before["panel_id"], "printf issue455-owned-reconnect\n")
        if not _wait(
            lambda: _io_progressed(
                reconnected_before,
                _panes_by_surface(c.peer_mirror_status()).get(transport_victim) or {},
            ),
            timeout_s=30,
        ):
            raise termmeshError(
                "owned pane transport reconnected but host output stayed frozen: "
                f"before={reconnected_before!r} "
                f"after={_panes_by_surface(c.peer_mirror_status()).get(transport_victim)!r}"
            )

        # ── 2. end one pane's relay, leaving its pane session alone.
        victim = sorted(after)[0]
        ended = c.peer_mirror_end_pane_relay(victim)
        if not ended.get("ok"):
            raise termmeshError(f"end pane relay refused: {ended!r}")

        def _victim_ended() -> bool:
            row = _panes_by_surface(c.peer_mirror_status()).get(victim) or {}
            return row.get("relay_liveness") == "ended"

        if not _wait(_victim_ended, timeout_s=30):
            raise termmeshError(
                f"pane {victim} relay never reported ended: {c.peer_mirror_status()!r}"
            )
        row = _panes_by_surface(c.peer_mirror_status())[victim]
        # The whole reason a start latch cannot decide this. If these ever
        # agree, the latch became a liveness signal and the three-way
        # classification can be simplified — until then, they must not.
        if row.get("relay_startup_state") != "started":
            raise termmeshError(
                "relay_startup_state stopped latching at `started`; the keep rule "
                f"was built around that latch: {row!r}"
            )
        if row.get("pane_torn_down") is not False:
            raise termmeshError(
                f"pane session tore down too — this test needs the relay-only case: {row!r}"
            )

        # A resync now must NOT keep it. Keeping on the latch would, and the
        # mapping would then outlive the reconnect: blank pane, host still
        # reporting its surface, no sweep able to reclaim it.
        dropped = c.peer_mirror_drop_subscription()
        if not dropped.get("dropped"):
            raise termmeshError(f"second subscription drop refused: {dropped!r}")

        def _second_resync() -> bool:
            m = c.peer_mirror_status()
            if not m.get("subscription_alive"):
                return False
            return (m.get("resync") or {}).get("respawned", 0) >= 1

        if not _wait(_second_resync, timeout_s=90):
            raise termmeshError(
                "resync kept the dead pane instead of respawning it: "
                f"{c.peer_mirror_status()!r}"
            )
        mirror = c.peer_mirror_status()
        resync = mirror.get("resync") or {}
        if resync.get("respawned") != 1:
            raise termmeshError(
                f"expected exactly the dead pane respawned, got {resync!r}"
            )
        if resync.get("kept") != base - 1:
            raise termmeshError(
                f"expected the {base - 1} live pane(s) kept, got {resync!r}"
            )

        # Identity again, from the other side: the dead pane's panel must be
        # replaced, and the live one's must not. Counters alone could be right
        # about the arithmetic and wrong about which pane each applied to.
        if not _wait(_all_live, timeout_s=90):
            raise termmeshError(
                f"mirror never returned to all-live panes: {c.peer_mirror_status()!r}"
            )
        final = _panes_by_surface(c.peer_mirror_status())
        if set(final) != set(after):
            raise termmeshError(
                f"surface set changed across the respawn: {sorted(after)} → {sorted(final)}"
            )
        if final[victim]["panel_id"] == after[victim]["panel_id"]:
            raise termmeshError(
                f"the dead pane kept its panel — it was never respawned: {final[victim]!r}"
            )
        for surface in final:
            if surface == victim:
                continue
            if final[surface]["panel_id"] != after[surface]["panel_id"]:
                raise termmeshError(
                    f"live pane {surface} was respawned alongside the dead one: "
                    f"{after[surface]['panel_id']} → {final[surface]['panel_id']}"
                )

        print("PASS: mirror reconnect keeps live panes and respawns dead ones")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
