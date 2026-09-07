#!/usr/bin/env python3
"""New Project must say how old a peer's Project roster is, and must never
refuse a name on a roster the host has not confirmed.

The symptom this guards against: a Project deleted on its host went on owning
its name for the rest of the session. Its roster read had started failing —
name resolution for the host's alias had stopped working — and a failed read
deliberately keeps the previous roster so one transient error cannot blank the
Projects a user is looking at. Nothing distinguished that kept roster from a
current one: `peer.host.list` still said `connected`, the New Project sheet
still rendered the record, and creation was blocked by it with no way to
refresh, no way past it, and no line anywhere saying the roster had stopped
refreshing. The `ListTeams` failure that started it logged nothing at all.

Covers, against a real peer host:
  1. A confirmed roster reports `teams_confirmed_at` and no failure, and
     `team_roster_verified` is true.
  2. A name a confirmed roster owns blocks creation and offers Open Existing —
     the rule below must not have turned every remote collision into a
     free-for-all.
  3. With the roster held in the state a failed read leaves it in, the same
     name no longer blocks creation, while the record is still reported so the
     sheet can explain itself.
  4. Clearing the failure restores the block.

The host is named by env because a peer test cannot invent a second machine.
`debug.peer.roster_failure` injects step 3 for the same reason: reproducing it
honestly needs a transport or DNS failure on a live machine.
"""
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

HOST_ENV = "TERMMESH_E2E_PEER_HOST"
REQUIRE_ENV = "TERMMESH_E2E_REQUIRE_PEER_HOST"
INJECTED_REASON = "e2e: the host did not answer ListTeams"


def host_row(client: termmesh, host: str) -> dict:
    for row in client.peer_host_list():
        if row.get("id") == host or row.get("display_name") == host:
            return row
    raise termmeshError(f"peer host {host!r} is not in peer.host.list")


def wait_for_confirmed_roster(client: termmesh, host: str, timeout_s: float = 90.0) -> dict:
    """Connect and wait for one successful roster read.

    The roster poll runs on its own schedule, so a connected host is not yet a
    host whose Projects have been read.
    """
    deadline = time.monotonic() + timeout_s
    client.peer_host_connect(host)
    last = {}
    while time.monotonic() < deadline:
        last = host_row(client, host)
        if last.get("team_roster_verified") is True:
            return last
        time.sleep(1.0)
    raise termmeshError(
        f"roster never confirmed for {host} within {timeout_s:.0f}s (last={last!r})"
    )


def main() -> int:
    host = os.environ.get(HOST_ENV, "").strip()
    if not host:
        if os.environ.get(REQUIRE_ENV) == "1":
            raise termmeshError(f"required peer host missing: set {HOST_ENV}")
        print(f"SKIP: set {HOST_ENV} to a reachable peer host")
        return 0

    with termmesh() as c:
        # 1. A confirmed roster says so, and says when.
        row = wait_for_confirmed_roster(c, host)
        host_id = str(row.get("id"))
        if not row.get("teams_confirmed_at"):
            raise termmeshError(f"confirmed roster reported no timestamp: {row!r}")
        if row.get("last_roster_failure"):
            raise termmeshError(
                f"confirmed roster still reports a failure: {row['last_roster_failure']!r}"
            )

        projects = c.debug_project_remote_presentations(host_id)
        if not projects:
            print(f"SKIP: {host} publishes no Project to collide with")
            return 0
        taken = str(projects[0].get("name") or "")
        if not taken:
            raise termmeshError(f"remote presentation has no name: {projects[0]!r}")

        # 2. A confirmed roster still owns its names.
        blocked = c.debug_project_name_conflict(taken, working_directory="/tmp/e2e-not-a-project")
        if blocked.get("conflict") != "remote_name_collision":
            raise termmeshError(
                f"expected remote_name_collision for {taken!r}, got {blocked!r}"
            )
        if blocked.get("blocks_create") is not True:
            raise termmeshError(f"a confirmed roster must still block: {blocked!r}")
        if blocked.get("roster_verified") is not True:
            raise termmeshError(f"record did not carry the confirmed roster: {blocked!r}")
        if blocked.get("action") != "open_existing":
            raise termmeshError(
                f"expected open_existing for a live remote Project, got {blocked!r}"
            )

        # 3. Held in the state a failed read leaves behind, it must not block.
        #    The 15s poll clears the injection on its next success, so inject
        #    and evaluate back to back rather than sleeping between them.
        injected = c.debug_peer_roster_failure(host_id, INJECTED_REASON)
        if injected.get("team_roster_verified") is not False:
            raise termmeshError(f"injecting a roster failure did not unverify: {injected!r}")
        unblocked = c.debug_project_name_conflict(taken, working_directory="/tmp/e2e-not-a-project")
        try:
            if unblocked.get("blocks_create") is not False:
                raise termmeshError(
                    "an unconfirmed roster still blocked creation — this is the defect: "
                    f"{unblocked!r}"
                )
            # The record must still be reported: the user needs to see what is
            # holding the name and where, not have it silently disappear.
            if unblocked.get("conflict") != "remote_name_collision":
                raise termmeshError(
                    f"the unconfirmed record stopped being reported: {unblocked!r}"
                )
            if unblocked.get("roster_verified") is not False:
                raise termmeshError(
                    f"record did not carry the unconfirmed roster: {unblocked!r}"
                )
        finally:
            # 4. Clearing it restores the block, whatever happened above.
            c.debug_peer_roster_failure(host_id)

        restored = c.debug_project_name_conflict(taken, working_directory="/tmp/e2e-not-a-project")
        if restored.get("blocks_create") is not True:
            raise termmeshError(f"clearing the failure did not restore the block: {restored!r}")

    print(
        f"PASS: {host} roster freshness is reported, and an unconfirmed roster "
        f"cannot block the name {taken!r}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
