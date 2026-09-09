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
            call("feed")
            wait(lambda s: s["matching_transcripts"] == 5)
            call("send")
            wait(lambda s: s["input_echoes"] == 1 and s["matching_transcripts"] == 5)
            call("reopen")
            reopened = wait(lambda s: s["viewer_panels"] == 6 and s["matching_transcripts"] == 5)
            assert reopened["viewer_id"] == initial["viewer_id"], reopened
            assert reopened["local_team_count"] == initial["local_team_count"], reopened
            call("reconnect")
            call("feed")
            recovered = wait(lambda s: s["viewer_panels"] == 6 and s["matching_transcripts"] == 5
                             and s["active_viewer_agents"] == 5
                             and s["viewer_agent_ids"] != initial["viewer_agent_ids"])
            assert recovered["source_id"] == initial["source_id"], recovered
            assert recovered["source_agent_ids"] == initial["source_agent_ids"], recovered
            assert recovered["input_echoes"] == 1, recovered
            subprocess.Popen(["/usr/bin/caffeinate", "-u", "-t", "10"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            client._call("debug.app.activate", {})
            subprocess.run(["/usr/sbin/screencapture", "-x", "/tmp/term-mesh-gui-live-e2e.png"], check=True)
        finally:
            call("cleanup")
    print("PASS: GUI Project exposes leader + five native workers, preserves transcripts and input across reconnect")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
