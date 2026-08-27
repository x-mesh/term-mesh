#!/usr/bin/env python3
"""Native dispatch latency bench — informational, always passes.

Run via the E2E runner on two checkouts (base vs branch) and compare the
BENCH lines. Against a fake-Codex native team it measures:
  A. single tm-agent send to one agent, repeated (per-call wall clock)
  B. four parallel sends to four distinct agents (total wall clock)
  C. team.broadcast RPC wall clock on the four-agent team
"""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


TEAM_NAME = f"bench-native-{uuid.uuid4().hex[:8]}"
AGENTS = [f"bench-a{i}-{uuid.uuid4().hex[:6]}" for i in range(1, 5)]
DEFAULTS_DOMAIN = "com.termmesh.app.debug"
DEFAULTS_KEY = "cliPath.codex"
SINGLE_SAMPLES = 12

FAKE_CODEX = r'''#!/usr/bin/env python3
import json
import sys

for raw in sys.stdin:
    try:
        request = json.loads(raw)
    except json.JSONDecodeError:
        continue
    request_id = request.get("id")
    method = request.get("method")
    if method == "initialize":
        print(json.dumps({"id": request_id, "result": {}}), flush=True)
    elif method == "thread/start":
        reply = {"id": request_id, "result": {"thread": {"id": "e2e-thread"}}}
        print(json.dumps(reply), flush=True)
    elif method == "turn/start":
        print(json.dumps({"id": request_id, "result": {"turn": {"id": "e2e-turn"}}}), flush=True)
        completed = {"method": "item/completed", "params": {"item": {
            "type": "agentMessage", "text": "pong"
        }}}
        print(json.dumps(completed), flush=True)
        done = {"method": "turn/completed", "params": {
            "threadId": "e2e-thread", "turn": {"status": "completed"}
        }}
        print(json.dumps(done), flush=True)
'''


def _read_default() -> tuple[bool, str]:
    proc = subprocess.run(
        ["defaults", "read", DEFAULTS_DOMAIN, DEFAULTS_KEY],
        text=True, capture_output=True, check=False,
    )
    return proc.returncode == 0, proc.stdout.rstrip("\n")


def _restore_default(existed: bool, value: str) -> None:
    if existed:
        subprocess.run(
            ["defaults", "write", DEFAULTS_DOMAIN, DEFAULTS_KEY, "-string", value],
            check=True,
        )
    else:
        subprocess.run(
            ["defaults", "delete", DEFAULTS_DOMAIN, DEFAULTS_KEY],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )


def _percentile(samples: list[float], fraction: float) -> float:
    ordered = sorted(samples)
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def main() -> int:
    repo = Path(__file__).resolve().parents[1]
    tm_agent = repo / "daemon" / "target" / "release" / "tm-agent"
    if not tm_agent.is_file():
        raise termmeshError(f"tm-agent binary not found: {tm_agent}")

    old_existed, old_value = _read_default()
    with tempfile.TemporaryDirectory(prefix="term-mesh-fake-codex-") as tmp:
        fake_codex = Path(tmp) / "codex"
        fake_codex.write_text(FAKE_CODEX)
        fake_codex.chmod(fake_codex.stat().st_mode | stat.S_IXUSR)
        subprocess.run(
            ["defaults", "write", DEFAULTS_DOMAIN, DEFAULTS_KEY,
             "-string", str(fake_codex)],
            check=True,
        )

        try:
            with termmesh() as client:
                client.team_create(TEAM_NAME, [])
                try:
                    env = os.environ.copy()
                    # Run against the app this bench launched, not the leader's.
                    # A leader pane exports a remote-leader route; inheriting it
                    # makes `tm-agent` proxy every call to the leader's host, so
                    # the numbers came from another machine — or the run failed
                    # with `noMatchingLeaderSession`, an error name that exists
                    # nowhere in this tree because a differently-versioned app
                    # answered.
                    for leaked in (
                        "TERMMESH_LEADER_GRANT_ID",
                        "TERMMESH_LEADER_PROJECT_ID",
                        "TERMMESH_LEADER_TEAM_UUID",
                        "TERMMESH_LEADER_EXPIRES_AT",
                        "TERMMESH_LEADER_PEER_ID",
                        "TERMMESH_LEADER_ROUTE_FILE",
                        "TERMMESH_PEER_SOCKET",
                    ):
                        env.pop(leaked, None)
                    env["TERMMESH_SOCKET"] = client.socket_path
                    env["TERMMESH_SOCKET_PATH"] = client.socket_path
                    env["TERMMESH_TEAM"] = TEAM_NAME
                    for agent in AGENTS:
                        add = subprocess.run(
                            [str(tm_agent), "add", "reviewer", "--name", agent,
                             "--cli", "codex", "--warmup", "--warmup-timeout", "20"],
                            cwd=repo, env=env, text=True, capture_output=True,
                            timeout=40, check=False,
                        )
                        if add.returncode != 0:
                            raise termmeshError(
                                f"add {agent} exited {add.returncode}:\n"
                                f"{add.stdout}{add.stderr}"
                            )

                    def send_once(agent: str, text: str) -> float:
                        start = time.monotonic()
                        proc = subprocess.run(
                            [str(tm_agent), "send", agent, text, "--no-report"],
                            cwd=repo, env=env, text=True, capture_output=True,
                            timeout=30, check=False,
                        )
                        elapsed = (time.monotonic() - start) * 1000.0
                        if proc.returncode != 0:
                            raise termmeshError(
                                f"send to {agent} exited {proc.returncode}:\n"
                                f"{proc.stdout}{proc.stderr}"
                            )
                        return elapsed

                    # A. Single-send wall clock, one agent, back to back.
                    send_once(AGENTS[0], "bench warmup")
                    singles = [
                        send_once(AGENTS[0], f"bench single {i}")
                        for i in range(SINGLE_SAMPLES)
                    ]

                    # B. Four parallel sends, four distinct agents.
                    start = time.monotonic()
                    procs = [
                        subprocess.Popen(
                            [str(tm_agent), "send", agent, "bench parallel",
                             "--no-report"],
                            cwd=repo, env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        )
                        for agent in AGENTS
                    ]
                    codes = [p.wait(timeout=30) for p in procs]
                    parallel_ms = (time.monotonic() - start) * 1000.0
                    if any(code != 0 for code in codes):
                        raise termmeshError(f"parallel sends exited {codes}")

                    # C. Broadcast RPC wall clock (the handler owns the stagger,
                    # so its response time is the dispatch schedule).
                    start = time.monotonic()
                    broadcast = client._call("team.broadcast", {
                        "team_name": TEAM_NAME,
                        "text": "bench broadcast\n",
                    })
                    broadcast_ms = (time.monotonic() - start) * 1000.0
                    if broadcast.get("sent_count") != len(AGENTS):
                        raise termmeshError(f"broadcast did not dispatch to all agents: {broadcast!r}")

                    print(
                        "BENCH single_send_ms "
                        f"p50={_percentile(singles, 0.5):.0f} "
                        f"p95={_percentile(singles, 0.95):.0f} "
                        f"samples={[round(s) for s in singles]}"
                    )
                    print(f"BENCH parallel4_total_ms={parallel_ms:.0f}")
                    print(f"BENCH broadcast4_rpc_ms={broadcast_ms:.0f}")
                finally:
                    client.team_destroy(TEAM_NAME)
        finally:
            _restore_default(old_existed, old_value)

    print("PASS: native dispatch latency bench recorded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
