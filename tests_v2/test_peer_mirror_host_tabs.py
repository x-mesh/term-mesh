#!/usr/bin/env python3
"""A mirrored pane shows every tab the host stacked in it.

The mirror used to map only each host pane's ACTIVE tab. A new tab becomes
active on both host kinds, so opening one closed the previous tab's local
panel and attached the new one: the host pane held N tabs while the mirror
pane held one, and the earlier tabs could not be reached from the viewer.

Asserted:
- a mirror opened on a pane that already holds 3 tabs starts every tab's
  relay, selects the host's active (middle) tab, and leaves it active;
- a tab opened from the mirror keeps every existing tab's local panel;
- selecting another tab in the mirror makes it active on the host, and the
  confirming push only selects it (no panel is respawned);
- closing one tab from the mirror closes that tab only.
In every step each mirror pane holds the same tabs as its host pane, in the
same order, with the same tab selected.

Loopback: the app mirrors its own workspace through the in-app peer server.
"""
import base64
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def _wait(predicate, timeout_s: float = 30.0, interval_s: float = 0.3):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval_s)
    return None


def _panes(c, workspace_id: str) -> list:
    """[(pane_id, [(panel_id, selected)])] in the order pane.list reports."""
    res = c._call("pane.list", {"workspace_id": workspace_id}) or {}
    out = []
    for pane in res.get("panes") or []:
        tabs = c._call(
            "pane.surfaces", {"workspace_id": workspace_id, "pane_id": pane["id"]}
        ) or {}
        out.append((
            pane["id"],
            [(s["id"], bool(s.get("selected"))) for s in tabs.get("surfaces") or []],
        ))
    return out


def _mirror_rows(c) -> dict:
    """host surface hex → mirror panel id. The status reports base64."""
    return {
        base64.b64decode(p["surface_id"]).hex(): p["panel_id"]
        for p in c.peer_mirror_status().get("panes") or []
    }


def _hex(panel_id: str) -> str:
    # A host terminal's wire surface id is its panel UUID's bytes.
    return panel_id.replace("-", "").lower()


def _shape(c, host_ws: str, mirror_ws: str):
    """Host and mirror tab layouts, both as host surface hex ids."""
    host = [[(_hex(t), sel) for t, sel in tabs] for _, tabs in _panes(c, host_ws)]
    panel_to_surface = {v: k for k, v in _mirror_rows(c).items()}
    mirror = [
        [(panel_to_surface.get(t, "?"), sel) for t, sel in tabs]
        for _, tabs in _panes(c, mirror_ws)
    ]
    return host, mirror


def _all_live(c, expected: int) -> bool:
    panes = c.peer_mirror_status().get("panes") or []
    return len(panes) == expected and all(p.get("relay_liveness") == "live" for p in panes)


def _require_converged(c, host_ws: str, mirror_ws: str, label: str) -> list:
    def _converged():
        host, mirror = _shape(c, host_ws, mirror_ws)
        return host if host == mirror else None

    host = _wait(_converged, timeout_s=20)
    if not host:
        host, mirror = _shape(c, host_ws, mirror_ws)
        raise termmeshError(f"{label}: mirror tabs differ from host tabs:\n host={host}\nmirror={mirror}")
    return host


def _require_kept(label: str, before: dict, after: dict) -> None:
    for surface, panel in before.items():
        if surface in after and after[surface] != panel:
            raise termmeshError(f"{label}: tab {surface} was respawned: {panel} → {after[surface]}")


def main() -> int:
    with termmesh() as c:
        # The mirror kick mirrors the selected workspace; make one this test owns.
        host_ws = c.new_workspace()
        time.sleep(1.0)
        surfaces = c.list_surfaces(host_ws)
        seed = next((s for _, s, focused in surfaces if focused), None)
        seed = seed or (surfaces[0][1] if surfaces else None)
        if not seed:
            raise termmeshError("fresh workspace has no seed surface")
        c.focus_surface(seed)
        if not _wait(lambda: c.read_terminal_text(seed).strip() != "", timeout_s=15):
            raise termmeshError("seed surface never rendered")
        c.new_split("right")
        time.sleep(1.0)

        # ── the host's first pane already holds 3 tabs, the MIDDLE one active,
        #    before any mirror exists. The mirror spawns the other two in the
        #    background, which no earlier pass ever had to do.
        host_first_pane = _panes(c, host_ws)[0][0]
        for _ in range(2):
            c._call("surface.create", {
                "workspace_id": host_ws, "pane_id": host_first_pane, "type": "terminal",
            })
            time.sleep(0.5)
        host_tabs = _panes(c, host_ws)[0][1]
        if len(host_tabs) != 3:
            raise termmeshError(f"host first pane should hold 3 tabs: {host_tabs}")
        middle = host_tabs[1][0]
        c.focus_surface(middle)
        time.sleep(1.0)

        kicked = c._call("debug.peer.open_workspace_mirror", {"live": True})
        if not (kicked or {}).get("started"):
            raise termmeshError(f"live mirror kick failed: {kicked!r}")
        if not _wait(lambda: _all_live(c, 4), timeout_s=90):
            raise termmeshError(
                f"mirror never reached 4 live tabs (background tabs included): {c.peer_mirror_status()!r}"
            )
        mirror_ws = c.peer_mirror_status().get("workspace_id")
        if not mirror_ws:
            raise termmeshError("mirror reports no workspace id")
        host = _require_converged(c, host_ws, mirror_ws, "open on a 3-tab pane")
        if host[0][1] != (_hex(middle), True):
            raise termmeshError(f"opening the mirror changed the host's active tab: {host}")
        before = _mirror_rows(c)

        # ── open a tab from the mirror. The request forwards to the host,
        #    which makes the new tab active; existing tabs keep their panels.
        first_mirror_pane = _panes(c, mirror_ws)[0][0]
        try:
            c._call("surface.create", {
                "workspace_id": mirror_ws, "pane_id": first_mirror_pane, "type": "terminal",
            })
        except termmeshError:
            pass  # forwarded: the mirror creates nothing locally
        if not _wait(lambda: _all_live(c, 5), timeout_s=60):
            raise termmeshError(f"mirror never mapped 5 live tabs: {c.peer_mirror_status()!r}")
        host = _require_converged(c, host_ws, mirror_ws, "new tab from the mirror")
        if [len(tabs) for tabs in host] != [4, 1]:
            raise termmeshError(f"host should hold 4 + 1 tabs: {host}")
        after = _mirror_rows(c)
        _require_kept("new tab from the mirror", before, after)

        # ── select the first (inactive) tab in the mirror; the host follows,
        #    and the confirming push respawns nothing.
        target_surface = host[0][0][0]
        c.focus_surface(after[target_surface])

        def _host_selected():
            host_now, mirror_now = _shape(c, host_ws, mirror_ws)
            ok = host_now[0][0] == (target_surface, True) and host_now == mirror_now
            return host_now if ok else None

        if not _wait(_host_selected, timeout_s=20):
            host_now, mirror_now = _shape(c, host_ws, mirror_ws)
            raise termmeshError(
                f"host did not follow the mirror's tab selection:\n host={host_now}\nmirror={mirror_now}"
            )
        if _mirror_rows(c) != after:
            raise termmeshError(f"selecting a tab respawned panels: {after} → {_mirror_rows(c)}")

        # ── close one inactive tab from the mirror: only that tab goes, on
        #    the host and in the mirror.
        host = _require_converged(c, host_ws, mirror_ws, "before close")
        victim = host[0][2][0]
        c.close_surface(after[victim])
        if not _wait(lambda: _all_live(c, 4), timeout_s=30):
            raise termmeshError(f"mirror did not drop to 4 tabs: {c.peer_mirror_status()!r}")
        host = _require_converged(c, host_ws, mirror_ws, "close one tab")
        if [len(tabs) for tabs in host] != [3, 1] or victim in [t for t, _ in host[0]]:
            raise termmeshError(f"closing one tab should leave 3 + 1 tabs without {victim}: {host}")
        remaining = {k: v for k, v in after.items() if k != victim}
        if _mirror_rows(c) != remaining:
            raise termmeshError(f"closing one tab respawned others: {remaining} → {_mirror_rows(c)}")

        print("PASS: a mirrored pane holds every host tab and its selection follows both ways")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
