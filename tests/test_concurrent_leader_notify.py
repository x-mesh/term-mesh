#!/usr/bin/env python3
"""
Concurrent leader notification test — reproduces Enter-swallow under simultaneous task.done.

Root cause:
  asyncTeamTaskDone → await MainActor.run { notifyTaskLifecycleEvent → sendToLeader
  → sendTextToPanel → sendIMEText(text, withReturn:true) }

  When 2-3 agents call task.done simultaneously, each schedules a MainActor.run block
  that calls sendIMEText. Even though MainActor serializes execution, the Ghostty PTY
  processes input asynchronously. The 5ms usleep between paste and Return may be
  insufficient when multiple sendIMEText calls land back-to-back without any stagger,
  causing one or more Return keys to be dropped.

Test scenarios:
  1. Simultaneous task.done from N agents (RPC-level race)
  2. Rapid sendTextToPanel without stagger (direct team.send overlap)
  3. Interleaved reply + task.done (mixed notification types)
  4. Burst: 5 task.done with zero gap (maximum stress)

Usage:
    python3 tests/test_concurrent_leader_notify.py
    python3 tests/test_concurrent_leader_notify.py --agents 3 --rounds 5
"""

import json
import os
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from termmesh import termmesh, termmeshError

# ── Config ──────────────────────────────────────────────────────────────────
TEAM_NAME = "concurrent-notify-test"
TMPDIR = Path(tempfile.gettempdir())
PID = os.getpid()

PASS_COUNT = 0
FAIL_COUNT = 0
SKIP_COUNT = 0


# ── Helpers ──────────────────────────────────────────────────────────────────

def marker(name: str) -> Path:
    return TMPDIR / f"concurrent_notify_{name}_{PID}"


def cleanup(*paths: Path):
    for p in paths:
        p.unlink(missing_ok=True)


def wait_marker(m: Path, timeout: float = 8.0) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        if m.exists():
            return True
        time.sleep(0.1)
    return False


def run_test(name: str, fn, *args):
    global PASS_COUNT, FAIL_COUNT, SKIP_COUNT
    n = PASS_COUNT + FAIL_COUNT + SKIP_COUNT + 1
    print(f"  [{n:2d}] {name} ... ", end="", flush=True)
    try:
        result = fn(*args)
        if result is None:
            result = True
        if result == "SKIP":
            print("SKIP")
            SKIP_COUNT += 1
        elif result:
            print("✅ PASS")
            PASS_COUNT += 1
        else:
            print("❌ FAIL")
            FAIL_COUNT += 1
    except Exception as e:
        print(f"❌ FAIL (exception: {e})")
        import traceback
        traceback.print_exc()
        FAIL_COUNT += 1


def detect_socket() -> str:
    env = os.environ.get("TERMMESH_SOCKET") or os.environ.get("TERMMESH_SOCKET_PATH")
    if env and os.path.exists(env):
        return env
    import glob as _glob
    candidates = sorted(_glob.glob("/tmp/term-mesh*.sock"), key=os.path.getmtime, reverse=True)
    for c in candidates:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(1)
            s.connect(c)
            s.close()
            return c
        except (OSError, socket.error):
            continue
    raise RuntimeError("No connectable term-mesh socket found")


def rpc(sock_path: str, method: str, params: dict, rid: int = 1, timeout: float = 10.0) -> dict:
    """One-shot JSON-RPC call."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(sock_path)
        s.sendall((json.dumps({"id": rid, "method": method, "params": params}) + "\n").encode())
        data = b""
        while b"\n" not in data:
            chunk = s.recv(8192)
            if not chunk:
                break
            data += chunk
        return json.loads(data.decode())
    finally:
        s.close()


def cleanup_team(sock_path: str):
    try:
        rpc(sock_path, "team.destroy", {"team_name": TEAM_NAME}, rid=999)
    except Exception:
        pass


def wait_screen_contains(client: termmesh, token: str, timeout: float = 8.0) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        try:
            if token in client.read_screen():
                return True
        except Exception:
            pass
        time.sleep(0.2)
    return False


# ── Scenario 1: Simultaneous task.done from N agents ─────────────────────────

def test_simultaneous_task_done(sock_path: str, client: termmesh, n_agents: int = 3):
    """
    Create N tasks, then fire all task.done RPCs simultaneously from N threads.

    Expected: leader terminal receives all N completion notifications, each
    with its own Enter → the leader's shell executes N lines.

    Failure mode: one or more Return keys dropped → leader sees concatenated
    lines or missing entries, and its shell prompt is stuck mid-command.
    """
    markers = [marker(f"simul_done_{i}") for i in range(n_agents)]
    cleanup(*markers)

    # Setup: create team with N pseudo-agents (no real Claude, just task slots)
    cleanup_team(sock_path)
    agent_specs = [{"name": f"a{i}", "model": "sonnet", "agent_type": "general"}
                   for i in range(n_agents)]
    resp = rpc(sock_path, "team.create", {
        "team_name": TEAM_NAME,
        "agents": agent_specs,
        "working_directory": os.getcwd(),
        "leader_session_id": f"concurrent-test-{PID}",
    })
    if not resp.get("ok"):
        print(f"(team.create failed: {resp.get('error')}) ", end="")
        return "SKIP"

    time.sleep(1.5)  # let leader pane initialize

    # Create N tasks, one per agent
    task_ids = []
    for i in range(n_agents):
        r = rpc(sock_path, "team.task.create", {
            "team_name": TEAM_NAME,
            "title": f"concurrent-task-{i}",
            "assignee": f"a{i}",
        }, rid=100 + i)
        if not r.get("ok"):
            print(f"(task.create[{i}] failed) ", end="")
            cleanup_team(sock_path)
            return "SKIP"
        task_ids.append(r["result"]["id"])

    # Mark tasks in_progress
    for i, tid in enumerate(task_ids):
        rpc(sock_path, "team.task.update", {
            "team_name": TEAM_NAME,
            "task_id": tid,
            "status": "in_progress",
        }, rid=200 + i)

    # Brief pause — then fire all task.done simultaneously from N threads
    barrier = threading.Barrier(n_agents)
    results = [None] * n_agents

    def do_done(idx: int, tid: str, m: Path):
        barrier.wait()  # synchronize all threads
        results[idx] = rpc(sock_path, "team.task.done", {
            "team_name": TEAM_NAME,
            "task_id": tid,
            "result": f"agent-{idx} done",
        }, rid=300 + idx, timeout=15.0)

    threads = [
        threading.Thread(target=do_done, args=(i, task_ids[i], markers[i]))
        for i in range(n_agents)
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=20)

    # Check all RPCs succeeded
    rpc_ok = all(r and r.get("ok") for r in results)
    if not rpc_ok:
        failed = [i for i, r in enumerate(results) if not (r and r.get("ok"))]
        print(f"(RPC failed for agents {failed}) ", end="")
        cleanup_team(sock_path)
        cleanup(*markers)
        return False

    # Now verify leader terminal received all N notifications with proper Enter.
    # We do this by sending N marker-touch commands immediately after,
    # interleaved with the expected notifications already delivered.
    # Simpler: check screen shows all N completion tokens.
    time.sleep(2.0)  # give notifications time to land
    try:
        screen = client.read_screen()
    except Exception:
        screen = ""

    # Each notification should appear as a separate line with "completed"
    # The key indicator: if Enter was dropped, lines will be concatenated.
    tokens_found = sum(1 for i in range(n_agents) if f"agent-{i}" in screen)
    print(f"(tokens={tokens_found}/{n_agents}) ", end="")

    # Secondary check: leader terminal is still responsive (Enter not stuck)
    responsive_marker = marker("simul_responsive")
    try:
        client.send(f"touch {responsive_marker}\n")
        responsive = wait_marker(responsive_marker, timeout=5.0)
    except Exception:
        responsive = False
    finally:
        cleanup(responsive_marker)

    cleanup_team(sock_path)
    cleanup(*markers)

    if not responsive:
        print("(leader terminal stuck — Enter was likely swallowed) ", end="")
        return False

    return True


# ── Scenario 2: Rapid team.send overlap (sendTextToPanel without stagger) ────

def test_rapid_team_send_to_leader(sock_path: str, client: termmesh, n: int = 5):
    """
    Send N messages to leader panel in rapid succession via team.send RPC,
    no delay between sends. Each must deliver text+Enter.

    This simulates sendTextToPanel being called N times without stagger —
    the same pattern that caused Enter swallowing in auto-warmup.
    """
    cleanup_team(sock_path)
    agent_specs = [{"name": "a0", "model": "sonnet", "agent_type": "general"}]
    resp = rpc(sock_path, "team.create", {
        "team_name": TEAM_NAME,
        "agents": agent_specs,
        "working_directory": os.getcwd(),
        "leader_session_id": f"rapid-send-test-{PID}",
    })
    if not resp.get("ok"):
        print(f"(team.create failed) ", end="")
        return "SKIP"

    time.sleep(1.5)

    # Get leader surface ID so we can check it's receiving input
    markers = [marker(f"rapid_send_{i}") for i in range(n)]
    cleanup(*markers)

    # Inject marker-touch commands directly into leader terminal
    # via team.send (which calls sendToLeader → sendTextToPanel)
    for i, m in enumerate(markers):
        rpc(sock_path, "team.send", {
            "team_name": TEAM_NAME,
            "agent_name": "leader",
            "text": f"touch {m}\n",
        }, rid=400 + i)
        # NO sleep — maximum stress

    # Wait for all markers
    time.sleep(5.0)
    missing = [i for i, m in enumerate(markers) if not m.exists()]

    print(f"(dropped {len(missing)}/{n}) ", end="")
    cleanup(*markers)
    cleanup_team(sock_path)

    return len(missing) == 0


# ── Scenario 3: Interleaved reply + task.done (mixed notification types) ─────

def test_interleaved_reply_and_task_done(sock_path: str, client: termmesh):
    """
    Simultaneously fire: team.agent.reply (report) + team.task.done.
    Both call sendToLeader back-to-back on MainActor.
    Verifies no Enter is dropped when notification types are mixed.
    """
    cleanup_team(sock_path)
    resp = rpc(sock_path, "team.create", {
        "team_name": TEAM_NAME,
        "agents": [{"name": "b0", "model": "sonnet", "agent_type": "general"},
                   {"name": "b1", "model": "sonnet", "agent_type": "general"}],
        "working_directory": os.getcwd(),
        "leader_session_id": f"interleaved-test-{PID}",
    })
    if not resp.get("ok"):
        return "SKIP"
    time.sleep(1.5)

    # Create a task
    r = rpc(sock_path, "team.task.create", {
        "team_name": TEAM_NAME,
        "title": "interleaved-task",
        "assignee": "b0",
    }, rid=500)
    if not r.get("ok"):
        cleanup_team(sock_path)
        return "SKIP"
    task_id = r["result"]["id"]
    rpc(sock_path, "team.task.update", {
        "team_name": TEAM_NAME,
        "task_id": task_id,
        "status": "in_progress",
    }, rid=501)

    barrier = threading.Barrier(3)
    results = [None, None, None]

    def do_reply():
        barrier.wait()
        results[0] = rpc(sock_path, "team.report", {
            "team_name": TEAM_NAME,
            "agent_name": "b1",
            "content": "b1-report-done",
        }, rid=502)

    def do_task_done():
        barrier.wait()
        results[1] = rpc(sock_path, "team.task.done", {
            "team_name": TEAM_NAME,
            "task_id": task_id,
            "result": "b0-task-done",
        }, rid=503)

    def do_heartbeat():
        barrier.wait()
        results[2] = rpc(sock_path, "team.agent.heartbeat", {
            "team_name": TEAM_NAME,
            "agent_name": "b0",
            "summary": "b0-heartbeat",
        }, rid=504)

    threads = [
        threading.Thread(target=do_reply),
        threading.Thread(target=do_task_done),
        threading.Thread(target=do_heartbeat),
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=15)

    rpc_ok = all(r and r.get("ok") for r in results)
    if not rpc_ok:
        failed = [i for i, r in enumerate(results) if not (r and r.get("ok"))]
        print(f"(RPC failed: {failed}) ", end="")
        cleanup_team(sock_path)
        return False

    time.sleep(2.0)

    # Verify leader terminal is still responsive
    responsive_marker = marker("interleaved_responsive")
    try:
        client.send(f"touch {responsive_marker}\n")
        responsive = wait_marker(responsive_marker, timeout=5.0)
    except Exception:
        responsive = False
    finally:
        cleanup(responsive_marker)

    cleanup_team(sock_path)

    if not responsive:
        print("(leader terminal stuck after mixed notifications) ", end="")
        return False
    return True


# ── Scenario 4: Burst — 5 task.done with zero gap ────────────────────────────

def test_burst_task_done(sock_path: str, client: termmesh, n: int = 5):
    """
    Fire 5 task.done RPCs sequentially with ZERO gap (no barrier, no sleep).
    Each one triggers sendToLeader → sendIMEText with withReturn=true.
    The 5ms usleep inside sendIMEText is the only throttle.

    This is the most aggressive reproduction of the concurrent Enter-drop bug.
    Expected after fix: all 5 delivered, leader terminal responsive.
    """
    cleanup_team(sock_path)
    agent_specs = [{"name": f"c{i}", "model": "sonnet", "agent_type": "general"}
                   for i in range(n)]
    resp = rpc(sock_path, "team.create", {
        "team_name": TEAM_NAME,
        "agents": agent_specs,
        "working_directory": os.getcwd(),
        "leader_session_id": f"burst-test-{PID}",
    })
    if not resp.get("ok"):
        return "SKIP"
    time.sleep(1.5)

    task_ids = []
    for i in range(n):
        r = rpc(sock_path, "team.task.create", {
            "team_name": TEAM_NAME,
            "title": f"burst-task-{i}",
            "assignee": f"c{i}",
        }, rid=600 + i)
        if not r.get("ok"):
            cleanup_team(sock_path)
            return "SKIP"
        task_ids.append(r["result"]["id"])
        rpc(sock_path, "team.task.update", {
            "team_name": TEAM_NAME,
            "task_id": r["result"]["id"],
            "status": "in_progress",
        }, rid=650 + i)

    # Fire all done RPCs with zero gap from a thread pool
    results = [None] * n
    barrier = threading.Barrier(n)

    def fire(idx: int):
        barrier.wait()
        results[idx] = rpc(sock_path, "team.task.done", {
            "team_name": TEAM_NAME,
            "task_id": task_ids[idx],
            "result": f"burst-{idx}",
        }, rid=700 + idx, timeout=15.0)

    threads = [threading.Thread(target=fire, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=20)

    ok_count = sum(1 for r in results if r and r.get("ok"))
    print(f"(rpc_ok={ok_count}/{n}) ", end="")

    if ok_count < n:
        cleanup_team(sock_path)
        return False

    time.sleep(3.0)

    # Verify terminal is still alive
    responsive_marker = marker("burst_responsive")
    try:
        client.send(f"touch {responsive_marker}\n")
        responsive = wait_marker(responsive_marker, timeout=6.0)
    except Exception:
        responsive = False
    finally:
        cleanup(responsive_marker)

    cleanup_team(sock_path)

    if not responsive:
        print("(terminal unresponsive after burst — Enter dropped) ", end="")
        return False
    return True


# ── Scenario 5: Baseline — sequential task.done (control) ────────────────────

def test_sequential_task_done_baseline(sock_path: str, client: termmesh, n: int = 3):
    """
    Control test: same as simultaneous but with 500ms stagger between each done.
    Should always pass. If this fails, the environment is broken.
    """
    cleanup_team(sock_path)
    agent_specs = [{"name": f"d{i}", "model": "sonnet", "agent_type": "general"}
                   for i in range(n)]
    resp = rpc(sock_path, "team.create", {
        "team_name": TEAM_NAME,
        "agents": agent_specs,
        "working_directory": os.getcwd(),
        "leader_session_id": f"sequential-test-{PID}",
    })
    if not resp.get("ok"):
        return "SKIP"
    time.sleep(1.5)

    task_ids = []
    for i in range(n):
        r = rpc(sock_path, "team.task.create", {
            "team_name": TEAM_NAME,
            "title": f"seq-task-{i}",
            "assignee": f"d{i}",
        }, rid=800 + i)
        if r.get("ok"):
            task_ids.append(r["result"]["id"])
            rpc(sock_path, "team.task.update", {
                "team_name": TEAM_NAME,
                "task_id": r["result"]["id"],
                "status": "in_progress",
            }, rid=850 + i)
        else:
            cleanup_team(sock_path)
            return "SKIP"

    for i, tid in enumerate(task_ids):
        rpc(sock_path, "team.task.done", {
            "team_name": TEAM_NAME,
            "task_id": tid,
            "result": f"seq-{i}",
        }, rid=900 + i)
        time.sleep(0.5)  # 500ms stagger — safe territory

    time.sleep(2.0)

    responsive_marker = marker("seq_responsive")
    try:
        client.send(f"touch {responsive_marker}\n")
        responsive = wait_marker(responsive_marker, timeout=6.0)
    except Exception:
        responsive = False
    finally:
        cleanup(responsive_marker)

    cleanup_team(sock_path)

    if not responsive:
        print("(baseline FAILED — environment issue) ", end="")
        return False
    return True


# ── Scenario 6: Stagger stress — 100ms gap (boundary condition) ──────────────

def test_stagger_100ms(sock_path: str, client: termmesh, n: int = 5):
    """
    Fire N task.done with 100ms gap. This is near the boundary where Enter
    drops start appearing (5ms usleep + MainActor scheduling overhead).
    Documents the minimum safe stagger interval.
    """
    cleanup_team(sock_path)
    agent_specs = [{"name": f"e{i}", "model": "sonnet", "agent_type": "general"}
                   for i in range(n)]
    resp = rpc(sock_path, "team.create", {
        "team_name": TEAM_NAME,
        "agents": agent_specs,
        "working_directory": os.getcwd(),
        "leader_session_id": f"stagger-test-{PID}",
    })
    if not resp.get("ok"):
        return "SKIP"
    time.sleep(1.5)

    task_ids = []
    for i in range(n):
        r = rpc(sock_path, "team.task.create", {
            "team_name": TEAM_NAME,
            "title": f"stagger-task-{i}",
            "assignee": f"e{i}",
        }, rid=1000 + i)
        if r.get("ok"):
            task_ids.append(r["result"]["id"])
            rpc(sock_path, "team.task.update", {
                "team_name": TEAM_NAME,
                "task_id": r["result"]["id"],
                "status": "in_progress",
            }, rid=1050 + i)
        else:
            cleanup_team(sock_path)
            return "SKIP"

    for i, tid in enumerate(task_ids):
        rpc(sock_path, "team.task.done", {
            "team_name": TEAM_NAME,
            "task_id": tid,
            "result": f"stagger-{i}",
        }, rid=1100 + i)
        time.sleep(0.1)  # 100ms — boundary

    time.sleep(3.0)

    responsive_marker = marker("stagger_responsive")
    try:
        client.send(f"touch {responsive_marker}\n")
        responsive = wait_marker(responsive_marker, timeout=6.0)
    except Exception:
        responsive = False
    finally:
        cleanup(responsive_marker)

    cleanup_team(sock_path)
    return responsive


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description="Concurrent leader notification Enter-drop test")
    parser.add_argument("--agents", type=int, default=3, help="Number of concurrent agents (default: 3)")
    parser.add_argument("--rounds", type=int, default=1, help="Repeat each test N times")
    args = parser.parse_args()

    print()
    print("═" * 70)
    print("  term-mesh: Concurrent Leader Notification / Enter-Drop Test Suite")
    print("═" * 70)
    print()

    try:
        sock_path = detect_socket()
    except RuntimeError as e:
        print(f"FATAL: {e}")
        print("Tip: start term-mesh first, or set TERMMESH_SOCKET=/tmp/term-mesh.sock")
        return 1

    print(f"  Socket: {sock_path}")
    print(f"  Agents: {args.agents}, Rounds: {args.rounds}")
    print()

    try:
        client = termmesh(sock_path)
        client.connect()
    except Exception as e:
        print(f"FATAL: Cannot connect to term-mesh: {e}")
        return 1

    # Ensure clean workspace for leader responsiveness checks
    try:
        ws = client.new_workspace()
        client.select_workspace(ws)
        time.sleep(0.5)
    except Exception:
        pass

    # Wait for shell
    for _ in range(20):
        try:
            s = client.read_screen()
            if any(ch in s for ch in ("➜", "❯", "$ ", "% ", "> ")):
                break
        except Exception:
            pass
        time.sleep(0.5)
    time.sleep(0.5)

    # Ensure clean team state
    cleanup_team(sock_path)

    for _round in range(args.rounds):
        if args.rounds > 1:
            print(f"  ── Round {_round + 1}/{args.rounds} ──")

        print("  ── Scenario 0: Baseline (sequential, 500ms stagger) ──")
        run_test(
            f"Sequential {args.agents}x task.done (control)",
            test_sequential_task_done_baseline, sock_path, client, args.agents
        )
        print()

        print("  ── Scenario 1: Simultaneous task.done from N agents ──")
        run_test(
            f"Simultaneous {args.agents}x task.done (no stagger)",
            test_simultaneous_task_done, sock_path, client, args.agents
        )
        print()

        print("  ── Scenario 2: Rapid team.send to leader (no stagger) ──")
        run_test(
            "5x rapid team.send to leader (sendTextToPanel flood)",
            test_rapid_team_send_to_leader, sock_path, client, 5
        )
        print()

        print("  ── Scenario 3: Interleaved reply + task.done + heartbeat ──")
        run_test(
            "Interleaved: reply + task.done + heartbeat simultaneously",
            test_interleaved_reply_and_task_done, sock_path, client
        )
        print()

        print("  ── Scenario 4: Burst (5 task.done, zero gap) ──")
        run_test(
            "Burst 5x task.done (maximum stress, zero gap)",
            test_burst_task_done, sock_path, client, 5
        )
        print()

        print("  ── Scenario 5: Stagger boundary (100ms gap) ──")
        run_test(
            "5x task.done with 100ms stagger (boundary condition)",
            test_stagger_100ms, sock_path, client, 5
        )
        print()

    client.close()

    total = PASS_COUNT + FAIL_COUNT + SKIP_COUNT
    print("═" * 70)
    print(f"  Results: {PASS_COUNT} passed, {FAIL_COUNT} failed, {SKIP_COUNT} skipped / {total} total")
    print("═" * 70)
    print()

    if FAIL_COUNT > 0:
        print(f"  ⚠️  {FAIL_COUNT} test(s) FAILED")
        print()
        print("  Diagnosis guide:")
        print("  - Scenario 1 FAIL: concurrent task.done notifications drop Enter")
        print("  - Scenario 2 FAIL: rapid sendTextToPanel calls drop Enter (flooding)")
        print("  - Scenario 3 FAIL: mixed notification types cause Enter interleave")
        print("  - Scenario 4 FAIL: burst sendIMEText calls overwhelm 5ms usleep")
        print("  - Scenario 5 FAIL: 100ms stagger insufficient (increase stagger or add queue)")
        print()
        print("  Fix: add notification queue / minimum stagger in sendToLeader, OR")
        print("       increase usleep in sendIMEText, OR serialize via DispatchSemaphore.")
        return 1

    print(f"  ✅ All {PASS_COUNT} tests passed — concurrent Enter delivery is solid!")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
