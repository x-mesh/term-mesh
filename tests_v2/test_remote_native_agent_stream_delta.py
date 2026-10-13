#!/usr/bin/env python3
"""A remote native agent pane receives its streaming answer as append patches.

mac-sub only (not run on the development host). Topology: a GUI host app that
owns a native Codex team backed by a fake CLI, and a viewer app that shows the
same pane through the live presentation protocol.

Required environment:
  TERMMESH_E2E_HOST_SOCKET     control socket of the host app (owns the agent)
  TERMMESH_E2E_VIEWER_SOCKET   control socket of the viewer app (attached to it)
  TERMMESH_E2E_DEFAULTS_DOMAIN bundle id whose `cliPath.codex` the host reads
  TERMMESH_E2E_TEAM            team name of the Project the viewer has open

The fake Codex streams a ~20 KiB Korean/emoji answer in many small deltas. The
test checks the viewer's text is byte-for-byte the host's, that it still is
after the viewer's relay is dropped and re-attached (a fresh full snapshot),
and that a second answer streams correctly afterwards. Byte savings are asserted
at unit level (AgentLiveAppendTests); here the contract is end-to-end equality.
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

REQUIRED = (
    "TERMMESH_E2E_HOST_SOCKET",
    "TERMMESH_E2E_VIEWER_SOCKET",
    "TERMMESH_E2E_DEFAULTS_DOMAIN",
    "TERMMESH_E2E_TEAM",
)
AGENT = "append-stream-e2e"
ANSWER_UNIT = "스트리밍 답변 👩‍👩‍👧 한글과 emoji, plain text. "

FAKE_CODEX = r'''#!/usr/bin/env python3
import json, sys, time
UNIT = %r
for raw in sys.stdin:
    try:
        request = json.loads(raw)
    except json.JSONDecodeError:
        continue
    rid, method = request.get("id"), request.get("method")
    if method == "initialize":
        print(json.dumps({"id": rid, "result": {}}), flush=True)
    elif method == "thread/start":
        print(json.dumps({"id": rid, "result": {"thread": {"id": "e2e-thread"}}}), flush=True)
    elif method == "turn/start":
        print(json.dumps({"id": rid, "result": {"turn": {"id": "e2e-turn"}}}), flush=True)
        text = ""
        while len(text.encode("utf-8")) < 20000:
            text += UNIT
            print(json.dumps({"method": "item/agentMessage/delta", "params": {"delta": UNIT}}), flush=True)
            time.sleep(0.01)
        print(json.dumps({"method": "item/completed", "params": {"item": {"type": "agentMessage", "text": text}}}), flush=True)
        print(json.dumps({"method": "turn/completed", "params": {"threadId": "e2e-thread", "turn": {"status": "completed"}}}), flush=True)
''' % ANSWER_UNIT


def answer_text(client: termmesh, agent: str) -> str:
    result = client._call("debug.agent.transcript", {"agent": agent})
    for row in result.get("agents", []):
        if row.get("agent") != agent:
            continue
        for entry in row.get("entries", []):
            if isinstance(entry, dict) and entry.get("kind") == "answered":
                return str(entry.get("text", ""))
            if isinstance(entry, str) and entry.startswith("answered"):
                return entry
    return ""


def wait_for(predicate, timeout: float, what: str):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(0.5)
    raise termmeshError(f"timed out waiting for {what}")


def main() -> int:
    missing = [name for name in REQUIRED if not os.environ.get(name)]
    if missing:
        print(f"SKIP: set {', '.join(missing)} (mac-sub two-app topology)")
        return 0
    domain = os.environ["TERMMESH_E2E_DEFAULTS_DOMAIN"]
    team = os.environ["TERMMESH_E2E_TEAM"]
    with tempfile.TemporaryDirectory(prefix="term-mesh-fake-codex-") as tmp:
        fake = Path(tmp) / "codex"
        fake.write_text(FAKE_CODEX)
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        subprocess.run(["defaults", "write", domain, "cliPath.codex", "-string", str(fake)], check=True)
        host = termmesh(socket_path=os.environ["TERMMESH_E2E_HOST_SOCKET"])
        viewer = termmesh(socket_path=os.environ["TERMMESH_E2E_VIEWER_SOCKET"])
        with host, viewer:
            host._call("team.add_agent", {
                "team_name": team, "agent_name": AGENT, "agent_type": "reviewer", "cli": "codex",
            })
            host._call("team.send", {"team_name": team, "agent": AGENT, "text": "stream the answer"})
            first = wait_for(
                lambda: (lambda t: t if len(t.encode()) >= 20000 else "")(answer_text(host, AGENT)),
                120, "the host answer to finish",
            )
            mirrored = wait_for(
                lambda: (lambda t: t if t == first else "")(answer_text(viewer, AGENT)),
                30, "the viewer to show the identical answer",
            )
            if mirrored.encode("utf-8") != first.encode("utf-8"):
                raise termmeshError("viewer answer differs from the host answer byte for byte")

            # A dropped relay must come back from a full snapshot, not a stale patch chain.
            viewer._call("debug.peer.mirror_drop_pane_transport", {})
            wait_for(lambda: answer_text(viewer, AGENT) == first, 60, "the viewer to recover the answer")

            host._call("team.send", {"team_name": team, "agent": AGENT, "text": "stream it again"})
            wait_for(lambda: answer_text(host, AGENT) != first, 120, "the second answer to start")
            wait_for(
                lambda: answer_text(viewer, AGENT) == answer_text(host, AGENT) and len(answer_text(host, AGENT).encode()) >= 20000,
                120, "the viewer to follow the second streamed answer",
            )
            host._call("team.remove_agent", {"team_name": team, "agent_name": AGENT})
    print("PASS: remote native agent streamed append-only text and recovered after a relay drop")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
