#!/usr/bin/env python3
"""GUI-owned Project: six panes, native transcripts, input and reconnect.

Runs only through the mac-sub runner. The fixture uses the real GUI peer
provider and native panes with deterministic in-memory agent transports.
"""
import subprocess
import time

from termmesh import termmesh, termmeshError


def main() -> int:
    with termmesh() as client:
        def call(action="status"):
            return client._call("debug.project.live_fixture", {"action": action})

        def wait(predicate, timeout=45):
            deadline = time.monotonic() + timeout
            last = None
            while time.monotonic() < deadline:
                last = call()
                if last.get("failure"):
                    raise termmeshError(str(last))
                if predicate(last):
                    return last
                time.sleep(0.1)
            raise termmeshError(f"live Project did not converge: {last}")

        try:
            call("start")
            initial = wait(lambda s: not s["starting"] and s["viewer_panels"] == 6
                           and s["source_panels"] == 6 and s["matching_transcripts"] == 5
                           and s["active_viewer_agents"] == 5)
            assert initial["review_board_visible"], initial
            assert initial["board_team"] == initial["source_team"], initial
            assert initial["board_workspace"] == initial["viewer_id"], initial
            assert initial["board_workers"] == 5, initial
            assert initial["board_delegation"] == "leaderFirst", initial
            assert initial["panel_remote"], initial
            assert initial["panel_delegation"] == "leaderFirst", initial
            client._call("debug.project.live_fixture", {
                "action": "delegation", "level": "delegated"
            })
            accepted = wait(lambda s: s["owner_delegation"] == "delegated")
            assert accepted["delegation_error"] == "", accepted
            authoritative = wait(lambda s: s["board_delegation"] == "delegated"
                                 and s["panel_delegation"] == "delegated")
            assert authoritative["owner_delegation"] == "delegated", authoritative
            call("invalid_identity")
            wait(lambda s: s["identity_refusal"] is True)
            call("feed")
            wait(lambda s: s["matching_transcripts"] == 5)
            call("send")
            wait(lambda s: s["input_echoes"] == 1 and s["matching_transcripts"] == 5)
            call("reopen")
            reopened = wait(lambda s: s["viewer_panels"] == 6 and s["matching_transcripts"] == 5)
            assert reopened["viewer_id"] == initial["viewer_id"], reopened
            assert reopened["local_team_count"] == initial["local_team_count"], reopened
            assert reopened["board_delegation"] == "delegated", reopened
            call("reconnect")
            call("feed")
            recovered = wait(lambda s: s["viewer_panels"] == 6 and s["matching_transcripts"] == 5
                             and s["active_viewer_agents"] == 5
                             and s["viewer_agent_ids"] != initial["viewer_agent_ids"])
            assert recovered["source_id"] == initial["source_id"], recovered
            assert recovered["source_agent_ids"] == initial["source_agent_ids"], recovered
            assert recovered["input_echoes"] == 1, recovered
            assert recovered["board_delegation"] == "delegated", recovered
            subprocess.Popen(["/usr/bin/caffeinate", "-u", "-t", "10"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            client._call("debug.app.activate", {})
            subprocess.run(["/usr/sbin/screencapture", "-x", "/tmp/term-mesh-gui-live-e2e.png"], check=True)
        finally:
            call("cleanup")
            wait(lambda s: not s["cleaning"] and s["viewer_id"] == "")
    print("PASS: GUI Project exposes leader + five native workers, preserves transcripts and input across reconnect")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
