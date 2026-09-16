#!/usr/bin/env python3
"""Reopen a GUI Project after its viewer window closes but its manager survives."""
import time
import subprocess

from termmesh import termmesh, termmeshError


def main():
    with termmesh() as client:
        source_window = client.list_windows()[0]["id"]
        viewer_window = client.new_window()

        def call(action="status", **params):
            return client._call("debug.project.live_fixture", {
                "action": action, "source_window_id": source_window, **params
            })

        def wait(predicate):
            deadline = time.monotonic() + 45
            last = None
            while time.monotonic() < deadline:
                last = call()
                if last.get("failure"):
                    raise termmeshError(str(last))
                if predicate(last):
                    return last
                time.sleep(0.1)
            raise termmeshError(f"Project reopen did not converge: {last}")

        # Keep the source in the original window, and the viewer in the second.
        client.focus_window(source_window)
        try:
            call("start", viewer_window_id=viewer_window)
            initial = wait(lambda s: not s["starting"] and s["viewer_panels"] == 6
                           and s["matching_transcripts"] == 5)
            assert initial["viewer_window_id"] == viewer_window, initial
            assert initial["source_window_id"] == source_window, initial
            client.close_window(viewer_window)
            call("reopen")
            reopened = wait(lambda s: s["viewer_panels"] == 6
                            and s["matching_transcripts"] == 5
                            and s["viewer_window_id"] == source_window)
            assert reopened["viewer_id"] != initial["viewer_id"], reopened
            assert reopened["source_id"] == initial["source_id"], reopened
            assert reopened["source_window_id"] == source_window, reopened
            assert reopened["source_agent_ids"] == initial["source_agent_ids"], reopened
            call("send")
            wait(lambda s: s["input_echoes"] == 1 and s["matching_transcripts"] == 5)
            call("reopen")
            assert call()["viewer_id"] == reopened["viewer_id"]
            client._call("workspace.select", {"workspace_id": reopened["viewer_id"]})
            client._call("debug.app.activate", {})
            subprocess.run(["/usr/sbin/screencapture", "-x",
                            "/tmp/term-mesh-project-window-reopen.png"], check=True)
        finally:
            call("cleanup")
            wait(lambda s: not s["cleaning"] and s["viewer_id"] == "")
    print("PASS: closed-window Project viewer reopens in the surviving window with live input")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
