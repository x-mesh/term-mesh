#!/usr/bin/env python3
"""Live term-meshd peer-federation workspace lifecycle e2e.

Deepens daemon-multi-workspace's t8: this drives a real `term-meshd` process
end to end through the peer wire protocol (protobuf, `TERMMESH_PEER_SOCKET`)
via `peer_client.PeerClient`/`TermMeshDaemon`, not the app's JSON socket --
pure-daemon e2e, so it needs no macOS app and runs locally (not VM-only like
`tests_v2/termmesh.py`-based tests).

Scenarios (each asserted before moving on):
  1. handshake + ListWorkspaces -> a single default workspace, already
     seeded with a pane at boot.
  2. CreateWorkspace("dev") -> appears in the roster with its own seeded
     pane, id != the default's.
  3. RenameWorkspace(dev_id, "dev2") -> title changes, id is stable.
  4. Kill + respawn the daemon against the SAME persisted state -> "dev2"
     survives the restart (same id) and still has a pane (post-boot reseed).
  5. DeleteWorkspace(dev2_id) -> a WorkspaceRemoved push is observed AND
     the roster drops back to just the default.
  6. The default workspace is deletable (a survivor is promoted in its
     place), but deleting the last remaining workspace is refused.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from peer_client import PeerClient, PeerClientError, TermMeshDaemon, WORKSPACE_LIFECYCLE_CAPABILITY


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PeerClientError(message)


def scenario_1_boot_default(client: PeerClient) -> bytes:
    """handshake + ListWorkspaces -> one seeded default workspace."""
    client.handshake()
    require(
        WORKSPACE_LIFECYCLE_CAPABILITY in client.host_capabilities,
        f"host did not advertise {WORKSPACE_LIFECYCLE_CAPABILITY!r}: {client.host_capabilities}",
    )

    workspaces = client.list_workspaces()
    require(len(workspaces) == 1, f"expected 1 workspace at fresh boot, got {len(workspaces)}: {workspaces}")
    default = workspaces[0]
    require(default.is_default, f"the only boot workspace must be default: {default}")
    require(default.pane_count >= 1, f"default workspace has no seeded pane: {default}")
    print(f"  scenario 1 PASS: default workspace {default.id_hex[:8]} seeded with {default.pane_count} pane(s)")
    return default.id


def scenario_2_create(client: PeerClient, default_id: bytes) -> bytes:
    """CreateWorkspace("dev") -> shows up with its own seeded pane."""
    dev_id = client.create_workspace("dev")
    require(dev_id and dev_id != default_id, f"create returned an empty/duplicate id: {dev_id!r}")

    workspaces = client.list_workspaces()
    require(len(workspaces) == 2, f"expected 2 workspaces after create, got {len(workspaces)}: {workspaces}")
    dev = next((w for w in workspaces if w.id == dev_id), None)
    require(dev is not None, f"newly created workspace {dev_id.hex()} missing from roster: {workspaces}")
    require(dev.title == "dev", f"expected title 'dev', got {dev.title!r}")
    require(not dev.is_default, "freshly created workspace must not be default")
    require(dev.pane_count >= 1, f"created workspace has no seeded pane: {dev}")
    print(f"  scenario 2 PASS: created 'dev' ({dev_id.hex()[:8]}) with {dev.pane_count} pane(s)")
    return dev_id


def scenario_3_rename(client: PeerClient, dev_id: bytes) -> None:
    """RenameWorkspace(dev_id, "dev2") -> title changes, id stable."""
    client.rename_workspace(dev_id, "dev2")

    workspaces = client.list_workspaces()
    dev2 = next((w for w in workspaces if w.id == dev_id), None)
    require(dev2 is not None, f"renamed workspace {dev_id.hex()} vanished: {workspaces}")
    require(dev2.title == "dev2", f"expected title 'dev2' after rename, got {dev2.title!r}")
    print(f"  scenario 3 PASS: renamed to 'dev2', id stable ({dev_id.hex()[:8]})")


def scenario_4_restart_persists(daemon: TermMeshDaemon, dev_id: bytes) -> None:
    """Kill + respawn the daemon against the same persisted state -> "dev2"
    survives with the same id and gets re-seeded a pane on boot."""
    daemon.restart()

    with PeerClient(str(daemon.peer_socket_path)) as client:
        client.handshake()
        workspaces = client.list_workspaces()
        require(
            len(workspaces) == 2,
            f"expected 2 workspaces to survive restart, got {len(workspaces)}: {workspaces}",
        )
        dev2 = next((w for w in workspaces if w.id == dev_id), None)
        require(dev2 is not None, f"'dev2' ({dev_id.hex()}) did not survive restart: {workspaces}")
        require(dev2.title == "dev2", f"title did not persist across restart, got {dev2.title!r}")
        require(dev2.pane_count >= 1, f"restarted workspace has no re-seeded pane: {dev2}")
    print(f"  scenario 4 PASS: 'dev2' ({dev_id.hex()[:8]}) survived restart with {dev2.pane_count} pane(s)")


def scenario_5_delete(client: PeerClient, default_id: bytes, dev_id: bytes) -> None:
    """DeleteWorkspace(dev2_id) -> WorkspaceRemoved push observed, roster
    drops back to just the default."""
    client.delete_workspace(dev_id)

    workspaces = client.list_workspaces()
    require(len(workspaces) == 1, f"expected 1 workspace after delete, got {len(workspaces)}: {workspaces}")
    require(workspaces[0].id == default_id, f"survivor should be the original default: {workspaces}")
    require(
        dev_id in client.workspace_removed_ids,
        f"never observed a WorkspaceRemoved push for {dev_id.hex()}: {client.workspace_removed_ids}",
    )
    print(f"  scenario 5 PASS: 'dev2' deleted, WorkspaceRemoved push observed, only default remains")


def scenario_6_default_deletable_last_refused(client: PeerClient, default_id: bytes) -> None:
    """The default workspace is deletable (promotes a survivor); deleting
    the LAST remaining workspace is refused (silent no-op)."""
    extra_id = client.create_workspace("extra")
    workspaces = client.list_workspaces()
    require(len(workspaces) == 2, f"expected 2 workspaces before default deletion, got {workspaces}")

    client.delete_workspace(default_id)
    workspaces = client.list_workspaces()
    require(len(workspaces) == 1, f"expected 1 workspace after deleting default, got {workspaces}")
    survivor = workspaces[0]
    require(survivor.id == extra_id, f"expected 'extra' promoted as survivor, got {survivor}")
    require(survivor.is_default, f"survivor must be promoted to default: {survivor}")
    require(
        default_id in client.workspace_removed_ids,
        f"never observed a WorkspaceRemoved push for the deleted default {default_id.hex()}",
    )
    print(f"  scenario 6a PASS: default deleted, 'extra' ({extra_id.hex()[:8]}) promoted to default")

    # Deleting the last remaining workspace must be refused: no removal,
    # no WorkspaceRemoved push, roster unchanged.
    removed_before = client.workspace_removed_ids.count(survivor.id)
    client.delete_workspace(survivor.id)
    workspaces = client.list_workspaces()
    require(len(workspaces) == 1, f"last workspace must survive a refused delete, got {workspaces}")
    require(workspaces[0].id == survivor.id, f"survivor id changed after a refused delete: {workspaces}")
    removed_after = client.workspace_removed_ids.count(survivor.id)
    require(
        removed_after == removed_before,
        "a WorkspaceRemoved push fired for the last-workspace delete, which must be refused",
    )
    print("  scenario 6b PASS: deleting the last remaining workspace was refused")


def main() -> int:
    daemon = TermMeshDaemon()
    try:
        daemon.start()

        with PeerClient(str(daemon.peer_socket_path)) as client:
            default_id = scenario_1_boot_default(client)
            dev_id = scenario_2_create(client, default_id)
            scenario_3_rename(client, dev_id)

        scenario_4_restart_persists(daemon, dev_id)

        with PeerClient(str(daemon.peer_socket_path)) as client:
            client.handshake()
            scenario_5_delete(client, default_id, dev_id)
            scenario_6_default_deletable_last_refused(client, default_id)
    finally:
        daemon.cleanup()

    print(
        "PASS: peer workspace lifecycle (create/rename/delete/restart-persistence/"
        "default-deletable/last-refused) against a live term-meshd"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PeerClientError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        raise SystemExit(1)
