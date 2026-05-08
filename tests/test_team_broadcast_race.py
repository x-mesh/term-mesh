#!/usr/bin/env python3
"""
Regression test: simultaneous broadcast delivers tasks to all 5 agents.

Reproduces the broadcast race condition where concurrent socket writes cause
some agents to miss the broadcast task entirely.

VM REQUIREMENT: This test requires a running term-mesh instance with
TERMMESH_SOCKET_MODE=allowAll and tm-agent available in PATH.
Run on UTM macOS VM:
    ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && python3 tests/test_team_broadcast_race.py'

Pre-fix expected: ≤2/5 agents receive each broadcast (race condition).
Post-fix expected: 5/5 agents receive each broadcast.
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime
from typing import Optional

# ── Constants ──────────────────────────────────────────────────────────────────

TEAM_NAME = "broadcast-race-test"
AGENT_COUNT = 5
BROADCAST_ROUNDS = 10
BROADCAST_TIMEOUT = 3.0   # seconds to wait for each round's delivery
PASS_THRESHOLD = AGENT_COUNT   # all agents must receive the task

PASS_COUNT = 0
FAIL_COUNT = 0
SKIP_COUNT = 0


# ── Helpers ────────────────────────────────────────────────────────────────────

def run_tm(args: list[str], timeout: float = 10.0) -> dict:
    """Run tm-agent with the given args and return parsed JSON output."""
    cmd = ["tm-agent"] + args
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        if result.returncode != 0:
            return {"ok": False, "error": result.stderr.strip() or f"exit {result.returncode}"}
        return json.loads(result.stdout.strip())
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"timeout after {timeout}s"}
    except json.JSONDecodeError as e:
        return {"ok": False, "error": f"json parse error: {e}"}
    except FileNotFoundError:
        return {"ok": False, "error": "tm-agent not found in PATH"}


def agent_name(i: int) -> str:
    return f"agent{i}"


def run_test(name: str, fn, *args):
    global PASS_COUNT, FAIL_COUNT, SKIP_COUNT
    n = PASS_COUNT + FAIL_COUNT + SKIP_COUNT + 1
    print(f"  [{n:2d}] {name} ... ", end="", flush=True)
    try:
        result = fn(*args)
        if result == "SKIP":
            print("SKIP")
            SKIP_COUNT += 1
        elif result:
            print("PASS")
            PASS_COUNT += 1
        else:
            print("FAIL")
            FAIL_COUNT += 1
    except Exception as e:
        print(f"ERROR: {e}")
        FAIL_COUNT += 1


# ── Setup / Teardown ───────────────────────────────────────────────────────────

def create_team() -> bool:
    """Create a test team with AGENT_COUNT agents."""
    resp = run_tm(["create", str(AGENT_COUNT)])
    if not resp.get("ok"):
        print(f"    team create failed: {resp.get('error', resp)}", file=sys.stderr)
        return False
    return True


def destroy_team():
    run_tm(["destroy"])


# ── Test: single broadcast round ───────────────────────────────────────────────

def get_task_list_for_agent(agent: str) -> list[dict]:
    """Return task list visible to the given agent."""
    resp = run_tm(["task", "list", "--agent", agent])
    if not resp.get("ok"):
        return []
    return resp.get("result", {}).get("tasks", [])


def count_agents_with_task(task_text: str, agent_names: list[str]) -> tuple[int, list[str]]:
    """Return (count, stuck_agents) for how many agents see a task containing task_text."""
    received = []
    stuck = []
    for name in agent_names:
        tasks = get_task_list_for_agent(name)
        titles = [t.get("title", "") for t in tasks]
        if any(task_text in t for t in titles):
            received.append(name)
        else:
            stuck.append(name)
    return len(received), stuck


def test_broadcast_single_round() -> bool:
    """One broadcast must reach all AGENT_COUNT agents."""
    agents = [agent_name(i) for i in range(AGENT_COUNT)]
    timestamp = datetime.utcnow().strftime("%H%M%S%f")
    message = f"ping {timestamp}"

    # Create task via broadcast
    resp = run_tm(["broadcast", message])
    if not resp.get("ok"):
        print(f"\n    broadcast failed: {resp.get('error', resp)}", file=sys.stderr)
        return False

    # Poll until all agents receive the task or timeout
    deadline = time.time() + BROADCAST_TIMEOUT
    last_count = 0
    stuck_agents: list[str] = agents[:]

    while time.time() < deadline:
        count, stuck = count_agents_with_task(message, agents)
        last_count = count
        stuck_agents = stuck
        if count >= PASS_THRESHOLD:
            return True
        time.sleep(0.2)

    print(f"\n    only {last_count}/{AGENT_COUNT} agents received task", file=sys.stderr)
    if stuck_agents:
        print(f"    stuck agents: {stuck_agents}", file=sys.stderr)
    return last_count >= PASS_THRESHOLD


def test_broadcast_repeated_rounds() -> bool:
    """Broadcast BROADCAST_ROUNDS times; all agents must receive every round."""
    agents = [agent_name(i) for i in range(AGENT_COUNT)]
    failures = []

    for round_num in range(BROADCAST_ROUNDS):
        timestamp = datetime.utcnow().strftime("%H%M%S%f")
        message = f"ping {timestamp}"

        resp = run_tm(["broadcast", message])
        if not resp.get("ok"):
            failures.append(f"round {round_num}: broadcast failed")
            continue

        deadline = time.time() + BROADCAST_TIMEOUT
        received_count = 0
        while time.time() < deadline:
            count, _ = count_agents_with_task(message, agents)
            received_count = count
            if count >= PASS_THRESHOLD:
                break
            time.sleep(0.1)

        if received_count < PASS_THRESHOLD:
            _, stuck = count_agents_with_task(message, agents)
            failures.append(
                f"round {round_num}: {received_count}/{AGENT_COUNT} received — stuck: {stuck}"
            )

    if failures:
        for f in failures:
            print(f"\n    {f}", file=sys.stderr)
        return False
    return True


def test_tm_agent_available() -> str:
    """Check that tm-agent is available; skip suite if not."""
    resp = run_tm(["status"])
    if resp.get("error") == "tm-agent not found in PATH":
        return "SKIP"
    return True


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    global PASS_COUNT, FAIL_COUNT, SKIP_COUNT

    print(f"\ntest_team_broadcast_race — {AGENT_COUNT} agents, {BROADCAST_ROUNDS} rounds")
    print("=" * 60)

    # Prerequisite check
    run_test("tm-agent available", test_tm_agent_available)
    if SKIP_COUNT > 0:
        print("\n  [SKIP] tm-agent not available — all tests skipped")
        print(f"\nResult: 0 passed, 0 failed, {SKIP_COUNT} skipped")
        sys.exit(0)

    # Teardown any leftover team from a previous run
    destroy_team()

    # Suite setup
    if not create_team():
        print("\n  [FATAL] Could not create team — aborting")
        sys.exit(2)

    try:
        run_test("broadcast single round all agents receive", test_broadcast_single_round)
        run_test(f"broadcast {BROADCAST_ROUNDS} rounds all agents receive", test_broadcast_repeated_rounds)
    finally:
        destroy_team()

    print("=" * 60)
    total = PASS_COUNT + FAIL_COUNT + SKIP_COUNT
    print(f"Result: {PASS_COUNT}/{total} passed, {FAIL_COUNT} failed, {SKIP_COUNT} skipped")

    if FAIL_COUNT > 0:
        print("\nPre-fix note: ≤2/5 pass rate is expected before the broadcast race fix.")
        print("Post-fix: all 5/5 agents must receive every broadcast.")
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
