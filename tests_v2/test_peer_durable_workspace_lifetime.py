#!/usr/bin/env python3
"""Negotiated durable workspaces survive detach and may become empty."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from peer_client import (
    PeerClient, PeerClientError, TermMeshDaemon,
    WORKSPACE_DURABLE_CAPABILITY, WORKSPACE_LIFECYCLE_CAPABILITY,
)


def require(value, message):
    if not value:
        raise PeerClientError(message)


def workspace(client, workspace_id):
    return next((row for row in client.list_workspaces() if row.id == workspace_id), None)


def main() -> int:
    daemon = TermMeshDaemon()
    try:
        daemon.start()
        with PeerClient(str(daemon.peer_socket_path)) as durable:
            durable.handshake()
            require(WORKSPACE_DURABLE_CAPABILITY in durable.host_capabilities, "host omitted durable capability")
            before_surfaces = {bytes(surface.surface_id) for surface in durable.list_surfaces()}
            workspace_id = durable.create_workspace("durable")
            first = workspace(durable, workspace_id)
            require(first and first.pane_count == 1, f"durable workspace not seeded: {first}")
            created = [
                surface for surface in durable.list_surfaces()
                if bytes(surface.surface_id) not in before_surfaces
            ]
            require(len(created) == 1, f"expected one durable seed surface, got {len(created)}")
            surface = created[0]
            durable.attach_surface(surface.surface_id)
            durable.detach_surface(surface.surface_id)
            require(any(s.surface_id == surface.surface_id for s in durable.list_surfaces()), "durable surface disappeared on detach")
            durable.close_workspace_pane(surface.surface_id)
            empty = workspace(durable, workspace_id)
            require(empty and empty.pane_count == 0, f"last durable pane did not leave an empty session: {empty}")
            durable.new_workspace_tab(workspace_id)
            restored = workspace(durable, workspace_id)
            require(restored and restored.pane_count == 1, f"New Pane did not repopulate empty session: {restored}")

        legacy_caps = [WORKSPACE_LIFECYCLE_CAPABILITY]
        with PeerClient(str(daemon.peer_socket_path), capabilities=legacy_caps) as legacy:
            legacy.handshake()
            before_surfaces = {bytes(surface.surface_id) for surface in legacy.list_surfaces()}
            workspace_id = legacy.create_workspace("legacy")
            row = workspace(legacy, workspace_id)
            require(row and row.pane_count == 1, f"legacy workspace not seeded: {row}")
            created = [
                surface for surface in legacy.list_surfaces()
                if bytes(surface.surface_id) not in before_surfaces
            ]
            require(len(created) == 1, f"expected one legacy seed surface, got {len(created)}")
            candidate = created[0]
            legacy.close_workspace_pane(candidate.surface_id)
            after = workspace(legacy, workspace_id)
            require(after and after.pane_count == 1, f"legacy last-pane close changed behavior: {after}")
    finally:
        daemon.cleanup()
    print("PASS: durable detach survives, last close empties, legacy close remains refused")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
