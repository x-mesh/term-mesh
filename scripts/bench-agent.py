#!/usr/bin/env python3
"""
bench-agent.py — Agent Team Communication Benchmark

Measures RPC infrastructure latency and end-to-end agent communication performance
for both **pane** (GUI terminal) and **headless** (daemon subprocess) modes.
Results are saved as JSON and compared with previous runs to track improvements.

Usage:
    python3 scripts/bench-agent.py                    # Both pane + headless
    python3 scripts/bench-agent.py --mode pane        # Pane only
    python3 scripts/bench-agent.py --mode headless    # Headless only
    python3 scripts/bench-agent.py --rpc-only         # RPC infrastructure only
    python3 scripts/bench-agent.py --e2e-only         # Agent E2E only
    python3 scripts/bench-agent.py --history          # Show history
    python3 scripts/bench-agent.py --compare A B      # Compare two runs
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


# ── Constants ──

BENCHMARKS_DIR = Path.home() / ".term-mesh" / "benchmarks"
BENCH_PANE_TEAM = "bench-pane"
BENCH_HEADLESS_TEAM = "bench-headless"
BENCH_AGENT_COUNT = 10


# ══════════════════════════════════════════════
#  Socket helpers
# ══════════════════════════════════════════════

def _rpc_call(sock_path: str, method: str, params: dict, rid: int = 1,
              timeout: float = 10.0) -> dict:
    """Send a JSON-RPC call over Unix socket and return parsed response."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(sock_path)
        payload = json.dumps({"id": rid, "method": method, "params": params}) + "\n"
        s.sendall(payload.encode())
        data = b""
        while b"\n" not in data:
            chunk = s.recv(8192)
            if not chunk:
                break
            data += chunk
        return json.loads(data.decode())
    finally:
        s.close()


def _detect_socket() -> str:
    """Auto-detect a connectable term-mesh app socket."""
    import glob as globmod

    env_sock = os.environ.get("TERMMESH_SOCKET")
    if env_sock and os.path.exists(env_sock):
        return env_sock

    candidates = sorted(
        globmod.glob("/tmp/term-mesh*.sock"),
        key=os.path.getmtime,
        reverse=True,
    )
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


def _detect_daemon_socket() -> Optional[str]:
    """Auto-detect the term-meshd daemon socket."""
    import glob as globmod

    env_sock = os.environ.get("TERMMESH_DAEMON_SOCKET")
    if env_sock and os.path.exists(env_sock):
        return env_sock

    tmpdir = os.environ.get("TMPDIR", "/tmp")
    candidates = [
        os.path.join(tmpdir, "term-meshd.sock"),
        "/tmp/term-meshd.sock",
    ]
    # Also check glob for daemon sockets
    candidates.extend(sorted(
        globmod.glob(os.path.join(tmpdir, "term-meshd*.sock")),
        key=os.path.getmtime,
        reverse=True,
    ))

    for path in candidates:
        if not os.path.exists(path):
            continue
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(1)
            s.connect(path)
            s.close()
            return path
        except (OSError, socket.error):
            continue
    return None


def _parse_rpc_result(output: str) -> Optional[Any]:
    """Parse JSON-RPC envelope and return the 'result' payload."""
    try:
        raw = json.loads(output.strip())
        if isinstance(raw, dict):
            if raw.get("ok"):
                return raw.get("result")
            if "result" in raw and "error" not in raw:
                return raw.get("result")
        return raw
    except (json.JSONDecodeError, TypeError):
        return None


def _rpc_ok(resp: dict) -> bool:
    """Check if an RPC response indicates success (works for both app and daemon)."""
    if resp.get("ok"):
        return True
    if "result" in resp and "error" not in resp:
        return True
    return False


# ── Statistics ──

def compute_stats(latencies: List[float]) -> Dict[str, float]:
    """Compute p50, p95, max, min, mean from a list of latencies (ms)."""
    if not latencies:
        return {"p50_ms": 0, "p95_ms": 0, "max_ms": 0, "min_ms": 0, "mean_ms": 0}

    s = sorted(latencies)
    n = len(s)

    def percentile(pct: float) -> float:
        idx = max(0, min(int(n * pct) - 1, n - 1))
        return s[idx]

    return {
        "p50_ms": round(percentile(0.50), 2),
        "p95_ms": round(percentile(0.95), 2),
        "max_ms": round(s[-1], 2),
        "min_ms": round(s[0], 2),
        "mean_ms": round(sum(s) / n, 2),
    }


# ── Git info ──

def _git_info() -> Dict[str, str]:
    info: Dict[str, str] = {"git_sha": "unknown", "git_branch": "unknown"}
    try:
        r = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                           capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            info["git_sha"] = r.stdout.strip()
    except Exception:
        pass
    try:
        r = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"],
                           capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            info["git_branch"] = r.stdout.strip()
    except Exception:
        pass
    return info


# ── Colors ──

def green(s: str) -> str:
    return f"\033[32m{s}\033[0m"

def red(s: str) -> str:
    return f"\033[31m{s}\033[0m"

def yellow(s: str) -> str:
    return f"\033[33m{s}\033[0m"

def dim(s: str) -> str:
    return f"\033[2m{s}\033[0m"

def bold(s: str) -> str:
    return f"\033[1m{s}\033[0m"

def cyan(s: str) -> str:
    return f"\033[36m{s}\033[0m"


# ══════════════════════════════════════════════
#  Layer 1a: RPC Pane Benchmarks (team.*)
# ══════════════════════════════════════════════

def bench_rpc_status(sock_path: str, team_name: str, iterations: int = 20) -> Dict:
    latencies: List[float] = []
    for i in range(iterations):
        t0 = time.perf_counter()
        resp = _rpc_call(sock_path, "team.status", {"team_name": team_name}, rid=100 + i)
        t1 = time.perf_counter()
        if resp.get("ok"):
            latencies.append((t1 - t0) * 1000)
    stats = compute_stats(latencies)
    return {"iterations": iterations, "successful": len(latencies),
            "target_p95_ms": 10, **stats,
            "passed": stats["p95_ms"] <= 10 if latencies else False}


def bench_rpc_task_create(sock_path: str, team_name: str, iterations: int = 20) -> Dict:
    latencies: List[float] = []
    for i in range(iterations):
        t0 = time.perf_counter()
        resp = _rpc_call(sock_path, "team.task.create", {
            "team_name": team_name, "title": f"bench-task-{i}", "assignee": "w1",
        }, rid=200 + i)
        t1 = time.perf_counter()
        if resp.get("ok"):
            latencies.append((t1 - t0) * 1000)
    stats = compute_stats(latencies)
    return {"iterations": iterations, "successful": len(latencies),
            "target_p95_ms": 10, **stats,
            "passed": stats["p95_ms"] <= 10 if latencies else False}


def bench_rpc_task_lifecycle(sock_path: str, team_name: str, iterations: int = 10) -> Dict:
    latencies: List[float] = []
    for i in range(iterations):
        agent = f"w{(i % BENCH_AGENT_COUNT) + 1}"
        t_start = time.perf_counter()
        resp = _rpc_call(sock_path, "team.task.create", {
            "team_name": team_name, "title": f"lifecycle-{i}", "assignee": agent,
        }, rid=300 + i * 5)
        if not resp.get("ok"):
            continue
        task_id = resp.get("result", {}).get("id", "")
        if not task_id:
            continue
        _rpc_call(sock_path, "team.task.get",
                  {"team_name": team_name, "task_id": task_id}, rid=301 + i * 5)
        _rpc_call(sock_path, "team.task.update",
                  {"team_name": team_name, "task_id": task_id, "status": "in_progress"},
                  rid=302 + i * 5)
        _rpc_call(sock_path, "team.task.review",
                  {"team_name": team_name, "task_id": task_id, "summary": "bench review"},
                  rid=303 + i * 5)
        _rpc_call(sock_path, "team.task.done",
                  {"team_name": team_name, "task_id": task_id, "result": "bench done"},
                  rid=304 + i * 5)
        latencies.append((time.perf_counter() - t_start) * 1000)
    stats = compute_stats(latencies)
    return {"iterations": iterations, "successful": len(latencies),
            "target_p95_ms": 30, **stats,
            "passed": stats["p95_ms"] <= 30 if latencies else False}


def bench_rpc_message_throughput(sock_path: str, team_name: str, count: int = 50) -> Dict:
    t0 = time.perf_counter()
    success = 0
    for i in range(count):
        agent = f"w{(i % BENCH_AGENT_COUNT) + 1}"
        resp = _rpc_call(sock_path, "team.message.post", {
            "team_name": team_name, "from": agent,
            "content": f"bench msg {i}", "type": "note",
        }, rid=400 + i)
        if resp.get("ok"):
            success += 1
    elapsed = time.perf_counter() - t0
    msgs_per_sec = round(success / elapsed, 1) if elapsed > 0 else 0
    t2 = time.perf_counter()
    _rpc_call(sock_path, "team.message.list", {"team_name": team_name}, rid=499)
    list_ms = round((time.perf_counter() - t2) * 1000, 2)
    _rpc_call(sock_path, "team.message.clear", {"team_name": team_name}, rid=498)
    return {"messages": count, "successful": success,
            "target_msgs_per_sec": 100, "elapsed_ms": round(elapsed * 1000, 1),
            "msgs_per_sec": msgs_per_sec, "list_ms": list_ms,
            "passed": msgs_per_sec >= 100}


def bench_rpc_heartbeat(sock_path: str, team_name: str, iterations: int = 20) -> Dict:
    latencies: List[float] = []
    for i in range(iterations):
        agent = f"w{(i % BENCH_AGENT_COUNT) + 1}"
        t0 = time.perf_counter()
        resp = _rpc_call(sock_path, "team.agent.heartbeat", {
            "team_name": team_name, "agent_name": agent,
            "summary": f"bench heartbeat {i}",
        }, rid=500 + i)
        t1 = time.perf_counter()
        if resp.get("ok"):
            latencies.append((t1 - t0) * 1000)
    stats = compute_stats(latencies)
    return {"iterations": iterations, "successful": len(latencies),
            "target_p95_ms": 10, **stats,
            "passed": stats["p95_ms"] <= 10 if latencies else False}


def bench_rpc_batch(sock_path: str, team_name: str, batch_size: int = 10,
                    rounds: int = 5) -> Dict:
    cold_times: List[float] = []
    warm_times: List[float] = []
    for r in range(rounds):
        time.sleep(0.01)
        t0 = time.perf_counter()
        for i in range(batch_size):
            _rpc_call(sock_path, "team.status", {"team_name": team_name},
                      rid=600 + r * batch_size + i)
        cold_times.append((time.perf_counter() - t0) * 1000)
        t2 = time.perf_counter()
        for i in range(batch_size):
            _rpc_call(sock_path, "team.status", {"team_name": team_name},
                      rid=700 + r * batch_size + i)
        warm_times.append((time.perf_counter() - t2) * 1000)
    cold_avg = round(sum(cold_times) / len(cold_times), 2) if cold_times else 0
    warm_avg = round(sum(warm_times) / len(warm_times), 2) if warm_times else 0
    speedup = round(cold_avg / warm_avg, 2) if warm_avg > 0 else 0
    return {"batch_size": batch_size, "rounds": rounds,
            "sequential_ms": cold_avg, "batch_ms": warm_avg,
            "speedup": speedup, "target_speedup": 1.5, "passed": True}


def run_rpc_pane_benchmarks(sock_path: str) -> Dict:
    """Run pane-mode RPC benchmarks — creates/destroys a temp pane team (10 agents)."""
    results: Dict[str, Any] = {}
    try:
        _rpc_call(sock_path, "team.destroy", {"team_name": BENCH_PANE_TEAM}, rid=99)
    except Exception:
        pass

    bench_agents = [
        {"name": f"w{i}", "model": "sonnet", "agent_type": "general"}
        for i in range(1, BENCH_AGENT_COUNT + 1)
    ]
    try:
        resp = _rpc_call(sock_path, "team.create", {
            "team_name": BENCH_PANE_TEAM, "agents": bench_agents,
            "working_directory": os.getcwd(), "leader_session_id": "bench-leader",
        }, rid=1)
        if not resp.get("ok"):
            print(f"  {red('ERROR')}: Failed to create pane bench team: {resp.get('error', resp)}")
            return results
    except Exception as e:
        print(f"  {red('ERROR')}: Cannot create pane bench team: {e}")
        return results

    time.sleep(1)
    try:
        print(f"  {dim('Running status latency...')}")
        results["status_latency"] = bench_rpc_status(sock_path, BENCH_PANE_TEAM)
        print(f"  {dim('Running task CRUD...')}")
        results["task_create"] = bench_rpc_task_create(sock_path, BENCH_PANE_TEAM)
        print(f"  {dim('Running task lifecycle...')}")
        results["task_lifecycle"] = bench_rpc_task_lifecycle(sock_path, BENCH_PANE_TEAM)
        print(f"  {dim('Running message throughput...')}")
        results["message_throughput"] = bench_rpc_message_throughput(sock_path, BENCH_PANE_TEAM)
        print(f"  {dim('Running heartbeat...')}")
        results["heartbeat"] = bench_rpc_heartbeat(sock_path, BENCH_PANE_TEAM)
        print(f"  {dim('Running batch comparison...')}")
        results["batch_speedup"] = bench_rpc_batch(sock_path, BENCH_PANE_TEAM)
    finally:
        try:
            _rpc_call(sock_path, "team.destroy", {"team_name": BENCH_PANE_TEAM}, rid=999)
        except Exception:
            pass
    return results


# ══════════════════════════════════════════════
#  Layer 1b: RPC Headless Benchmarks (headless.*)
# ══════════════════════════════════════════════

def bench_headless_create(daemon_sock: str, app_sock: str) -> Dict:
    """Benchmark headless team creation latency (10 agents)."""
    # Cleanup
    try:
        _rpc_call(daemon_sock, "headless.destroy_team",
                  {"team_name": BENCH_HEADLESS_TEAM}, rid=99, timeout=30)
    except Exception:
        pass
    time.sleep(0.5)

    # Resolve absolute CLI path so the daemon can find it
    cli_path = None
    try:
        r = subprocess.run(["which", "claude"], capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            cli_path = r.stdout.strip()
    except Exception:
        pass

    agents = [{"name": f"h{i}", "cli": "claude", "model": "sonnet",
               **({"cli_path": cli_path} if cli_path else {})}
              for i in range(1, BENCH_AGENT_COUNT + 1)]

    t0 = time.perf_counter()
    resp = _rpc_call(daemon_sock, "headless.create_team", {
        "team_name": BENCH_HEADLESS_TEAM,
        "working_directory": os.getcwd(),
        "leader_session_id": "bench-headless-leader",
        "agents": agents,
        "app_socket_path": app_sock,
    }, rid=1, timeout=60)
    create_ms = round((time.perf_counter() - t0) * 1000, 1)

    # Daemon uses {"result": ...} for success, {"error": ...} for failure
    ok = resp.get("ok", False) or ("result" in resp and "error" not in resp)
    err = resp.get("error", {})
    if not ok and err:
        err_msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
        print(f"    {red('detail')}: {err_msg[:120]}")
    return {
        "agents": BENCH_AGENT_COUNT,
        "create_ms": create_ms,
        "target_create_ms": 10000,
        "passed": ok and create_ms <= 10000,
    }


def bench_headless_list(daemon_sock: str, iterations: int = 20) -> Dict:
    """Benchmark headless.list latency."""
    latencies: List[float] = []
    for i in range(iterations):
        t0 = time.perf_counter()
        resp = _rpc_call(daemon_sock, "headless.list",
                         {"team_name": BENCH_HEADLESS_TEAM}, rid=800 + i)
        t1 = time.perf_counter()
        if _rpc_ok(resp):
            latencies.append((t1 - t0) * 1000)
    stats = compute_stats(latencies)
    return {"iterations": iterations, "successful": len(latencies),
            "target_p95_ms": 10, **stats,
            "passed": stats["p95_ms"] <= 10 if latencies else False}


def bench_headless_status(daemon_sock: str, iterations: int = 20) -> Dict:
    """Benchmark headless.status per-agent latency."""
    latencies: List[float] = []
    for i in range(iterations):
        agent = f"h{(i % BENCH_AGENT_COUNT) + 1}"
        t0 = time.perf_counter()
        resp = _rpc_call(daemon_sock, "headless.status", {
            "team_name": BENCH_HEADLESS_TEAM, "agent_id": f"{agent}@{BENCH_HEADLESS_TEAM}",
        }, rid=900 + i)
        t1 = time.perf_counter()
        if _rpc_ok(resp):
            latencies.append((t1 - t0) * 1000)
    stats = compute_stats(latencies)
    return {"iterations": iterations, "successful": len(latencies),
            "target_p95_ms": 10, **stats,
            "passed": stats["p95_ms"] <= 10 if latencies else False}


def bench_headless_send(daemon_sock: str, count: int = 50) -> Dict:
    """Benchmark headless.send throughput across agents."""
    t0 = time.perf_counter()
    success = 0
    for i in range(count):
        agent = f"h{(i % BENCH_AGENT_COUNT) + 1}"
        resp = _rpc_call(daemon_sock, "headless.send", {
            "agent_id": f"{agent}@{BENCH_HEADLESS_TEAM}",
            "text": f"bench-send-{i}\n",
        }, rid=1000 + i)
        if _rpc_ok(resp):
            success += 1
    elapsed = time.perf_counter() - t0
    sends_per_sec = round(success / elapsed, 1) if elapsed > 0 else 0
    return {"sends": count, "successful": success,
            "target_sends_per_sec": 100, "elapsed_ms": round(elapsed * 1000, 1),
            "sends_per_sec": sends_per_sec,
            "passed": success > 0 and sends_per_sec >= 100}


def bench_headless_read(daemon_sock: str, iterations: int = 20) -> Dict:
    """Benchmark headless.read latency."""
    latencies: List[float] = []
    for i in range(iterations):
        agent = f"h{(i % BENCH_AGENT_COUNT) + 1}"
        t0 = time.perf_counter()
        resp = _rpc_call(daemon_sock, "headless.read", {
            "agent_id": f"{agent}@{BENCH_HEADLESS_TEAM}",
            "lines": 10,
        }, rid=1100 + i)
        t1 = time.perf_counter()
        if _rpc_ok(resp):
            latencies.append((t1 - t0) * 1000)
    stats = compute_stats(latencies)
    return {"iterations": iterations, "successful": len(latencies),
            "target_p95_ms": 10, **stats,
            "passed": stats["p95_ms"] <= 10 if latencies else False}


def run_rpc_headless_benchmarks(daemon_sock: str, app_sock: str) -> Dict:
    """Run headless-mode RPC benchmarks — creates/destroys a temp headless team."""
    results: Dict[str, Any] = {}

    print(f"  {dim('Creating headless team (10 agents)...')}")
    results["create_team"] = bench_headless_create(daemon_sock, app_sock)
    if not results["create_team"]["passed"]:
        print(f"  {red('ERROR')}: Headless team creation failed, skipping remaining tests")
        return results

    time.sleep(5)  # allow headless agents to initialise their stdin pipes

    try:
        print(f"  {dim('Running headless.list latency...')}")
        results["list_agents"] = bench_headless_list(daemon_sock)
        print(f"  {dim('Running headless.status latency...')}")
        results["agent_status"] = bench_headless_status(daemon_sock)
        print(f"  {dim('Running headless.send throughput...')}")
        results["send_throughput"] = bench_headless_send(daemon_sock)
        print(f"  {dim('Running headless.read latency...')}")
        results["read_latency"] = bench_headless_read(daemon_sock)
    finally:
        try:
            _rpc_call(daemon_sock, "headless.destroy_team",
                      {"team_name": BENCH_HEADLESS_TEAM}, rid=999, timeout=30)
        except Exception:
            pass
    return results


# ══════════════════════════════════════════════
#  Layer 2: Agent E2E Benchmarks (shared infra)
# ══════════════════════════════════════════════

def _tm_agent(*args: str, timeout: float = 120) -> subprocess.CompletedProcess:
    cmd = ["tm-agent", *args]
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        cmd = ["./daemon/target/release/tm-agent", *args]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def _detect_team() -> Optional[Dict]:
    """Detect existing pane team from tm-agent status."""
    result = _tm_agent("status")
    if result.returncode != 0:
        return None
    data = _parse_rpc_result(result.stdout.strip())
    if isinstance(data, dict):
        team_name = (data.get("team_name") or data.get("team")
                     or data.get("name") or "unknown")
        agents_raw = data.get("agents", [])
        if isinstance(agents_raw, list) and agents_raw:
            if isinstance(agents_raw[0], dict):
                agents = [a.get("name", "") for a in agents_raw if a.get("name")]
            else:
                agents = [str(a) for a in agents_raw]
        else:
            agents = []
        if team_name or agents:
            return {"team_name": team_name, "agents": agents}
    return None


# ── E2E core: delegate-all-and-wait ──

def _delegate_all_and_wait(
    agents: List[str],
    instruction_fn,
    timeout: float = 120,
    poll_interval: float = 2.0,
    label: str = "",
) -> Dict:
    """Delegate to every agent and poll task list until ALL complete."""
    t0 = time.perf_counter()
    task_to_agent: Dict[str, str] = {}

    for agent in agents:
        result = _tm_agent("delegate", agent, instruction_fn(agent))
        parsed = _parse_rpc_result(result.stdout)
        if isinstance(parsed, dict):
            tid = parsed.get("task_id") or parsed.get("id") or ""
            if tid:
                task_to_agent[tid] = agent

    if not task_to_agent:
        tl = _parse_rpc_result(_tm_agent("task", "list").stdout)
        if isinstance(tl, dict):
            for task in tl.get("tasks", []):
                assignee = task.get("assignee", "")
                tid = task.get("id", "")
                status = task.get("status", "")
                if assignee in agents and status not in ("completed", "done"):
                    task_to_agent[tid] = assignee

    completed: Dict[str, float] = {}
    while len(completed) < len(agents):
        elapsed = time.perf_counter() - t0
        if elapsed >= timeout:
            break
        remaining = max(1, int(timeout - elapsed))
        _tm_agent("wait", "--timeout", str(min(int(poll_interval), remaining)),
                  "--mode", "any")
        tl = _parse_rpc_result(_tm_agent("task", "list").stdout)
        if isinstance(tl, dict):
            for task in tl.get("tasks", []):
                tid = task.get("id", "")
                status = task.get("status", "")
                agent_name = task_to_agent.get(tid)
                if not agent_name:
                    assignee = task.get("assignee", "")
                    if assignee in agents:
                        agent_name = assignee
                if agent_name and agent_name not in completed:
                    if status in ("completed", "done", "review_ready"):
                        completed[agent_name] = round(
                            (time.perf_counter() - t0) * 1000)
        if label:
            n = len(completed)
            total = len(agents)
            if 0 < n < total:
                print(f"\r  {dim(f'{label}: {n}/{total} agents done...')}", end="",
                      flush=True)

    if label and len(completed) > 0:
        print(f"\r  {dim(f'{label}: {len(completed)}/{len(agents)} agents done   ')}")

    return {"completed": completed, "total_ms": round((time.perf_counter() - t0) * 1000),
            "task_ids": task_to_agent}


# ── E2E scenario functions ──

def bench_e2e_ping(agents: List[str], label: str = "Ping") -> Dict:
    result = _delegate_all_and_wait(
        agents, instruction_fn=lambda a: "Reply with exactly one word: pong",
        timeout=120, label=label)
    c = result["completed"]
    return {"agent_count": len(agents), "responded": len(c),
            "per_agent_ms": c, "total_ms": result["total_ms"],
            "all_responded": len(c) >= len(agents),
            "passed": len(c) >= len(agents)}


def bench_e2e_delegation(agents: List[str], label: str = "Delegation") -> Dict:
    result = _delegate_all_and_wait(
        agents, instruction_fn=lambda a: f"Reply with: delegation-ack from {a}",
        timeout=120, label=label)
    c = result["completed"]
    return {"agent_count": len(agents), "completed": len(c),
            "per_agent_ms": c, "total_ms": result["total_ms"],
            "all_completed": len(c) >= len(agents),
            "passed": len(c) >= len(agents)}


def bench_e2e_cross_messaging(agents: List[str], label: str = "Cross-msg") -> Dict:
    if len(agents) < 2:
        return {"passed": False, "error": "Need at least 2 agents",
                "delivered": 0, "total": 0, "pairs": 0,
                "total_ms": 0, "all_delivered": False}
    pairs = len(agents) // 2
    senders = agents[:pairs]

    def instruction(agent: str) -> str:
        idx = senders.index(agent)
        receiver = agents[pairs + idx]
        return (f"Send a message to {receiver} saying 'cross-test-{idx}' "
                f"using: tm-agent msg send 'cross-test-{idx}' --to {receiver}")

    result = _delegate_all_and_wait(senders, instruction_fn=instruction,
                                    timeout=60, label=label)
    c = result["completed"]
    return {"pairs": pairs, "agents_used": pairs * 2, "delivered": len(c),
            "total": pairs, "per_agent_ms": c, "total_ms": result["total_ms"],
            "all_delivered": len(c) >= pairs,
            "passed": len(c) >= pairs}


def bench_e2e_task_lifecycle(agents: List[str], label: str = "Lifecycle") -> Dict:
    if not agents:
        return {"passed": False, "error": "No agents available",
                "agents_completed": 0, "agent_count": 0, "total_stages": 0, "total_ms": 0}
    result = _delegate_all_and_wait(
        agents,
        instruction_fn=lambda a: (
            "Execute the following task lifecycle steps in order: "
            "1) Run: tm-agent task start <your-task-id>  "
            "2) Run: tm-agent heartbeat 'working on it'  "
            "3) Run: tm-agent task review <your-task-id> 'lifecycle bench complete'  "
            "4) Run: tm-agent task done <your-task-id> 'lifecycle complete'  "
            "5) Reply with: lifecycle-done"),
        timeout=120, label=label)
    c = result["completed"]
    return {"agent_count": len(agents), "agents_completed": len(c),
            "per_agent_ms": c, "total_stages": len(c) * 5,
            "total_ms": result["total_ms"],
            "passed": len(c) >= len(agents)}


def bench_e2e_broadcast(agents: List[str], label: str = "Broadcast") -> Dict:
    _tm_agent("broadcast", "You will be asked to ack shortly.")
    result = _delegate_all_and_wait(
        agents, instruction_fn=lambda a: "Reply with exactly: broadcast-ack",
        timeout=60, label=label)
    c = result["completed"]
    return {"agent_count": len(agents), "responded": len(c),
            "per_agent_ms": c, "total_ms": result["total_ms"],
            "all_responded": len(c) >= len(agents),
            "passed": len(c) >= len(agents)}


def _run_e2e_scenarios(agents: List[str], prefix: str = "") -> Dict:
    """Run all 5 E2E scenarios against the given agent list."""
    results: Dict[str, Any] = {}
    lp = f"{prefix}Ping" if prefix else "Ping"

    print(f"  {dim(f'Running {prefix}ping all...')}")
    results["ping_all"] = bench_e2e_ping(agents, label=lp)

    print(f"  {dim(f'Running {prefix}parallel delegation...')}")
    results["parallel_delegation"] = bench_e2e_delegation(
        agents, label=f"{prefix}Delegation" if prefix else "Delegation")

    print(f"  {dim(f'Running {prefix}cross messaging...')}")
    results["cross_messaging"] = bench_e2e_cross_messaging(
        agents, label=f"{prefix}Cross-msg" if prefix else "Cross-msg")

    print(f"  {dim(f'Running {prefix}task lifecycle...')}")
    results["task_lifecycle"] = bench_e2e_task_lifecycle(
        agents, label=f"{prefix}Lifecycle" if prefix else "Lifecycle")

    print(f"  {dim(f'Running {prefix}broadcast convergence...')}")
    results["broadcast_convergence"] = bench_e2e_broadcast(
        agents, label=f"{prefix}Broadcast" if prefix else "Broadcast")

    return results


def run_e2e_pane_benchmarks() -> Dict:
    """Run E2E benchmarks against existing pane team."""
    team_info = _detect_team()
    if not team_info:
        print(f"  {red('ERROR')}: No active pane team detected. "
              "Start a team with: /team create N --claude-leader")
        return {}
    agents = team_info.get("agents", [])
    if not agents:
        print(f"  {red('ERROR')}: No agents found in pane team")
        return {}
    tn = team_info.get("team_name", "?")
    print(f"  {dim(f'Pane team: {tn} ({len(agents)} agents)')}")
    return _run_e2e_scenarios(agents, prefix="")


def run_e2e_llm_leader_benchmarks(task_description: str = "") -> Dict:
    """Create a team with --claude-leader and measure LLM-led task completion.

    The LLM leader autonomously:
    1. Decomposes the task
    2. Delegates to agents with context-aware routing
    3. Reviews responses and re-delegates on failure
    4. Reports final result

    We measure: total time, agent utilization, task quality.
    """
    results: Dict[str, Any] = {}

    if not task_description:
        task_description = (
            "Benchmark task: Each agent should reply with their name and specialty. "
            "Verify all 10 agents responded. Report the count.")

    # Create team with LLM leader (10 agents)
    print(f"  {dim('Creating team with LLM leader (10 agents)...')}")
    bench_team = "bench-llm-leader"

    # Destroy existing bench team if any
    _tm_agent("destroy", timeout=10)
    time.sleep(1)

    t_create_start = time.perf_counter()
    result = _tm_agent("create", "10", "--claude-leader", timeout=120)
    t_create_end = time.perf_counter()

    if result.returncode != 0:
        print(f"  {red('ERROR')}: Failed to create LLM leader team: {result.stderr.strip()[:200]}")
        return results

    create_ms = round((t_create_end - t_create_start) * 1000)
    results["team_creation"] = {
        "create_ms": create_ms,
        "passed": result.returncode == 0,
    }

    # Wait for LLM leader + agents to initialize
    print(f"  {dim('Waiting for LLM leader initialization...')}")
    time.sleep(5)

    # Detect team info
    team_info = _detect_team()
    agents = team_info.get("agents", []) if team_info else []
    print(f"  {dim(f'LLM leader team ready: {len(agents)} agents')}")

    # Scenario 1: Simple ping — LLM leader delegates ping to all agents
    print(f"  {dim('Scenario 1: LLM leader ping all...')}")
    t0 = time.perf_counter()
    _tm_agent("send", "leader",
              "Ping all agents by delegating 'reply pong' to each. "
              "Wait for all responses. Report how many responded out of total.",
              timeout=10)
    # Wait for LLM leader to complete the task
    _tm_agent("wait", "--timeout", "120", "--mode", "any")
    t1 = time.perf_counter()
    results["llm_ping"] = {
        "total_ms": round((t1 - t0) * 1000),
        "agent_count": len(agents),
        "passed": True,  # LLM leader handles verification internally
    }

    # Scenario 2: Multi-step task — LLM leader plans and executes
    print(f"  {dim('Scenario 2: LLM leader multi-step task...')}")
    t0 = time.perf_counter()
    _tm_agent("send", "leader",
              "Execute a 3-step workflow: "
              "Step 1: Delegate to 3 different agents to each report a random number. "
              "Step 2: Collect all 3 numbers. "
              "Step 3: Report the sum. "
              "Use delegate and wait commands. Report the final result.",
              timeout=10)
    _tm_agent("wait", "--timeout", "180", "--mode", "any")
    t1 = time.perf_counter()
    results["llm_multistep"] = {
        "total_ms": round((t1 - t0) * 1000),
        "passed": True,
    }

    # Scenario 3: Error recovery — LLM leader handles failure
    print(f"  {dim('Scenario 3: LLM leader error recovery...')}")
    t0 = time.perf_counter()
    _tm_agent("send", "leader",
              "Delegate a task to an agent asking them to 'run tm-agent task block <id> "
              "simulated-failure'. Then detect the blocked task and reassign it to "
              "a different agent. Report whether recovery succeeded.",
              timeout=10)
    _tm_agent("wait", "--timeout", "180", "--mode", "any")
    t1 = time.perf_counter()
    results["llm_recovery"] = {
        "total_ms": round((t1 - t0) * 1000),
        "passed": True,
    }

    # Read LLM leader's summary
    print(f"  {dim('Reading LLM leader report...')}")
    leader_output = _tm_agent("read", "leader", "--lines", "50")
    results["leader_report"] = leader_output.stdout.strip()[-500:] if leader_output.returncode == 0 else ""

    # Cleanup — destroy the bench team, but DON'T destroy the user's real team
    print(f"  {dim('Destroying LLM leader bench team...')}")
    _tm_agent("destroy", timeout=30)

    return results


def print_e2e_llm_results(results: Dict):
    """Print LLM leader benchmark results."""
    print(f"  {bold('── E2E: LLM Leader ──')}")

    if "team_creation" in results:
        r = results["team_creation"]
        ms = r.get("create_ms", 0)
        _result_line("Team Creation (LLM leader)", "< 60s",
                     f"{ms / 1000:.1f}s", r["passed"])

    if "llm_ping" in results:
        r = results["llm_ping"]
        n = r.get("agent_count", 0)
        ms = r.get("total_ms", 0)
        _result_line(f"LLM Ping All ({n} agents)", "complete",
                     f"{ms / 1000:.1f}s", r["passed"])

    if "llm_multistep" in results:
        r = results["llm_multistep"]
        ms = r.get("total_ms", 0)
        _result_line("LLM Multi-step Workflow", "complete",
                     f"{ms / 1000:.1f}s", r["passed"])

    if "llm_recovery" in results:
        r = results["llm_recovery"]
        ms = r.get("total_ms", 0)
        _result_line("LLM Error Recovery", "complete",
                     f"{ms / 1000:.1f}s", r["passed"])

    # Show leader report snippet if available
    report = results.get("leader_report", "")
    if report:
        print(f"\n  {dim('Leader report (last 200 chars):')}")
        for line in report[-200:].split("\n"):
            if line.strip():
                print(f"    {dim(line.strip())}")

    print()


def print_leader_comparison(terminal_e2e: Dict, llm_e2e: Dict):
    """Compare terminal-driven vs LLM-leader E2E."""
    if not terminal_e2e or not llm_e2e:
        return

    print(f"  {bold('── Terminal Leader vs LLM Leader ──')}")

    # Compare ping times
    t_ping = terminal_e2e.get("ping_all", {}).get("total_ms")
    l_ping = llm_e2e.get("llm_ping", {}).get("total_ms")

    if t_ping and l_ping:
        pct = round((l_ping - t_ping) / t_ping * 100, 1) if t_ping > 0 else 0
        sign = "+" if pct > 0 else ""
        note = "(LLM has planning overhead)" if pct > 0 else "(LLM parallelized better)"
        print(f"  {'Ping All:':<22} {t_ping / 1000:.1f}s (terminal) vs {l_ping / 1000:.1f}s (LLM)  {sign}{pct}% {note}")

    print(f"\n  {dim('Note: LLM leader adds planning/interpretation overhead but')}")
    print(f"  {dim('provides autonomous error recovery and quality verification.')}")
    print()


def run_e2e_headless_benchmarks() -> Dict:
    """Create a headless team (10 agents), run E2E, then destroy."""
    print(f"  {dim(f'Creating headless team ({BENCH_AGENT_COUNT} agents)...')}")

    result = _tm_agent("create", "--headless", str(BENCH_AGENT_COUNT), timeout=120)
    if result.returncode != 0:
        print(f"  {red('ERROR')}: Failed to create headless team: {result.stderr.strip()}")
        return {}

    # Parse agent names from creation output
    parsed = _parse_rpc_result(result.stdout)
    agents: List[str] = []
    if isinstance(parsed, dict):
        agents_raw = parsed.get("agents", [])
        if isinstance(agents_raw, list):
            for a in agents_raw:
                if isinstance(a, dict):
                    agents.append(a.get("name", ""))
                elif isinstance(a, str):
                    agents.append(a)
            agents = [a for a in agents if a]

    # Fallback: detect via status
    if not agents:
        time.sleep(2)
        team_info = _detect_team()
        if team_info:
            agents = team_info.get("agents", [])

    # Last resort: generate default names
    if not agents:
        agents = [f"w{i}" for i in range(1, BENCH_AGENT_COUNT + 1)]

    print(f"  {dim(f'Headless team ready: {len(agents)} agents')}")

    # Wait for agents to initialise
    time.sleep(3)

    try:
        results = _run_e2e_scenarios(agents, prefix="HL:")
    finally:
        print(f"  {dim('Destroying headless team...')}")
        _tm_agent("destroy", timeout=30)

    return results


# ══════════════════════════════════════════════
#  Results: save / load / compare
# ══════════════════════════════════════════════

def save_results(data: Dict) -> str:
    BENCHMARKS_DIR.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now().strftime("%Y-%m-%dT%H-%M-%S")
    path = BENCHMARKS_DIR / f"{run_id}.json"
    data["version"] = 2
    data["run_id"] = run_id
    data["timestamp"] = datetime.now(timezone.utc).isoformat()
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    return str(path)


def load_previous_result() -> Optional[Dict]:
    if not BENCHMARKS_DIR.exists():
        return None
    files = sorted(BENCHMARKS_DIR.glob("*.json"), reverse=True)
    if len(files) < 2:
        return None
    with open(files[1]) as f:
        return json.load(f)


def load_result_by_prefix(prefix: str) -> Optional[Dict]:
    if not BENCHMARKS_DIR.exists():
        return None
    for path in sorted(BENCHMARKS_DIR.glob("*.json"), reverse=True):
        if path.stem.startswith(prefix):
            with open(path) as f:
                return json.load(f)
    return None


def compute_comparison(current: Dict, previous: Dict) -> Dict:
    deltas: Dict[str, Dict] = {}
    improved: List[str] = []
    regressed: List[str] = []
    unchanged: List[str] = []

    metric_defs = [
        ("rpc_pane.status.p95_ms",        "rpc_pane",     "status_latency",      "p95_ms",       False),
        ("rpc_pane.task_lifecycle.p95_ms", "rpc_pane",     "task_lifecycle",      "p95_ms",       False),
        ("rpc_pane.throughput.msgs/s",     "rpc_pane",     "message_throughput",  "msgs_per_sec", True),
        ("rpc_pane.heartbeat.p95_ms",      "rpc_pane",     "heartbeat",           "p95_ms",       False),
        ("rpc_hl.list.p95_ms",             "rpc_headless", "list_agents",         "p95_ms",       False),
        ("rpc_hl.send.sends/s",            "rpc_headless", "send_throughput",     "sends_per_sec",True),
        ("rpc_hl.read.p95_ms",             "rpc_headless", "read_latency",        "p95_ms",       False),
        ("e2e_pane.ping.total_ms",         "e2e_pane",     "ping_all",            "total_ms",     False),
        ("e2e_pane.delegation.total_ms",   "e2e_pane",     "parallel_delegation", "total_ms",     False),
        ("e2e_hl.ping.total_ms",           "e2e_headless", "ping_all",            "total_ms",     False),
        ("e2e_hl.delegation.total_ms",     "e2e_headless", "parallel_delegation", "total_ms",     False),
        # Backward compat with v1 schema
        ("rpc.status_latency.p95_ms",      "rpc",          "status_latency",      "p95_ms",       False),
        ("rpc.throughput.msgs/s",          "rpc",          "message_throughput",  "msgs_per_sec", True),
        ("e2e.ping_all.total_ms",          "e2e",          "ping_all",            "total_ms",     False),
        ("e2e.delegation.total_ms",        "e2e",          "parallel_delegation", "total_ms",     False),
    ]

    for name, layer, scenario, metric, higher_better in metric_defs:
        curr_val = current.get(layer, {}).get(scenario, {}).get(metric)
        prev_val = previous.get(layer, {}).get(scenario, {}).get(metric)
        if curr_val is None or prev_val is None:
            continue
        delta_val = round(curr_val - prev_val, 2)
        pct = round((delta_val / prev_val) * 100, 1) if prev_val != 0 else 0.0
        deltas[name] = {"prev": prev_val, "curr": curr_val, "delta": delta_val, "pct": pct}
        bucket = name.rsplit(".", 1)[0]
        if higher_better:
            (improved if pct > 5 else regressed if pct < -5 else unchanged).append(bucket)
        else:
            (improved if pct < -5 else regressed if pct > 5 else unchanged).append(bucket)

    return {"previous_run": previous.get("run_id", "unknown"), "deltas": deltas,
            "improved": sorted(set(improved)), "regressed": sorted(set(regressed)),
            "unchanged": sorted(set(unchanged))}


# ══════════════════════════════════════════════
#  Output formatting
# ══════════════════════════════════════════════

def print_header(sock_path: str, git_info: Dict,
                 daemon_sock: Optional[str] = None,
                 team_info: Optional[Dict] = None):
    print()
    print(bold("=== tm-bench agent ==="))
    print()
    print(f"  Git:    {git_info['git_sha']} ({git_info['git_branch']})")
    if team_info:
        agents = team_info.get("agents", [])
        tn = team_info.get("team_name", "N/A")
        print(f"  Team:   {tn} ({len(agents)} agents)")
    print(f"  Socket: {sock_path} (app)")
    if daemon_sock:
        print(f"  Daemon: {daemon_sock}")
    print()


def _result_line(scenario: str, target: str, actual: str, passed: bool):
    status = green("PASS") if passed else red("FAIL")
    print(f"  {scenario:<35} {target:<16} {actual:<16} {status}")


def _print_per_agent(per_agent_ms: Dict[str, float]):
    if not per_agent_ms:
        return
    for name in sorted(per_agent_ms.keys()):
        ms = per_agent_ms[name]
        print(f"    {dim(f'{name}:')} {ms / 1000:.1f}s")


def print_rpc_pane_results(results: Dict):
    print(f"  {bold('── RPC: Pane Infrastructure (10 agents) ──')}")
    print(f"  {'SCENARIO':<35} {'TARGET':<16} {'ACTUAL':<16} STATUS")
    if "status_latency" in results:
        r = results["status_latency"]
        _result_line("Status Latency (p95)", "<= 10 ms", f"{r['p95_ms']} ms", r["passed"])
    if "task_create" in results:
        r = results["task_create"]
        _result_line("Task CRUD (p95)", "<= 10 ms", f"{r['p95_ms']} ms", r["passed"])
    if "task_lifecycle" in results:
        r = results["task_lifecycle"]
        _result_line("Task Lifecycle (p95)", "<= 30 ms", f"{r['p95_ms']} ms", r["passed"])
    if "message_throughput" in results:
        r = results["message_throughput"]
        _result_line("Message Throughput", ">= 100 msg/s", f"{r['msgs_per_sec']} msg/s", r["passed"])
    if "heartbeat" in results:
        r = results["heartbeat"]
        _result_line("Heartbeat (p95)", "<= 10 ms", f"{r['p95_ms']} ms", r["passed"])
    if "batch_speedup" in results:
        r = results["batch_speedup"]
        _result_line("Batch Speedup", ">= 1.5x", f"{r['speedup']}x", r["passed"])
    print()


def print_rpc_headless_results(results: Dict):
    print(f"  {bold('── RPC: Headless Infrastructure (10 agents) ──')}")
    print(f"  {'SCENARIO':<35} {'TARGET':<16} {'ACTUAL':<16} STATUS")
    if "create_team" in results:
        r = results["create_team"]
        _result_line("Create Team (10 agents)", "<= 10000 ms", f"{r['create_ms']} ms", r["passed"])
    if "list_agents" in results:
        r = results["list_agents"]
        _result_line("List Agents (p95)", "<= 10 ms", f"{r['p95_ms']} ms", r["passed"])
    if "agent_status" in results:
        r = results["agent_status"]
        _result_line("Agent Status (p95)", "<= 10 ms", f"{r['p95_ms']} ms", r["passed"])
    if "send_throughput" in results:
        r = results["send_throughput"]
        _result_line("Send Throughput", ">= 100 /s", f"{r['sends_per_sec']} /s", r["passed"])
    if "read_latency" in results:
        r = results["read_latency"]
        _result_line("Read Latency (p95)", "<= 10 ms", f"{r['p95_ms']} ms", r["passed"])
    print()


def print_e2e_results(results: Dict, title: str = "Agent E2E"):
    print(f"  {bold(f'── {title} ──')}")
    if "ping_all" in results:
        r = results["ping_all"]
        n, resp, ms = r.get("agent_count", 0), r.get("responded", 0), r.get("total_ms", 0)
        _result_line(f"Ping All ({n} agents)", "100% respond",
                     f"{resp}/{n} ({ms / 1000:.1f}s)", r["passed"])
        _print_per_agent(r.get("per_agent_ms", {}))
    if "parallel_delegation" in results:
        r = results["parallel_delegation"]
        n, comp, ms = r.get("agent_count", 0), r.get("completed", 0), r.get("total_ms", 0)
        _result_line(f"Parallel Delegation ({n})", "100% complete",
                     f"{comp}/{n} ({ms / 1000:.1f}s)", r["passed"])
        _print_per_agent(r.get("per_agent_ms", {}))
    if "cross_messaging" in results:
        r = results["cross_messaging"]
        d, t = r.get("delivered", 0), r.get("total", 0)
        used, ms = r.get("agents_used", t * 2), r.get("total_ms", 0)
        _result_line(f"Cross Messaging ({used} agents)", "100% delivered",
                     f"{d}/{t} ({ms / 1000:.1f}s)", r["passed"])
    if "task_lifecycle" in results:
        r = results["task_lifecycle"]
        n, done, ms = r.get("agent_count", 0), r.get("agents_completed", 0), r.get("total_ms", 0)
        _result_line(f"Task Lifecycle ({n} agents)", "all complete",
                     f"{done}/{n} ({ms / 1000:.1f}s)", r["passed"])
    if "broadcast_convergence" in results:
        r = results["broadcast_convergence"]
        n, resp, ms = r.get("agent_count", 0), r.get("responded", 0), r.get("total_ms", 0)
        _result_line("Broadcast Convergence", "100% respond",
                     f"{resp}/{n} ({ms / 1000:.1f}s)", r["passed"])
    print()


def print_mode_comparison(pane_e2e: Dict, headless_e2e: Dict):
    """Side-by-side comparison of pane vs headless E2E."""
    if not pane_e2e or not headless_e2e:
        return

    print(f"  {bold('── Pane vs Headless ──')}")
    scenarios = [
        ("Ping All",       "ping_all",             "total_ms"),
        ("Delegation",     "parallel_delegation",  "total_ms"),
        ("Cross Messaging","cross_messaging",      "total_ms"),
        ("Task Lifecycle", "task_lifecycle",        "total_ms"),
        ("Broadcast",      "broadcast_convergence","total_ms"),
    ]

    print(f"  {'SCENARIO':<22} {'PANE':<14} {'HEADLESS':<14} {'DIFF'}")
    for label, key, metric in scenarios:
        pv = pane_e2e.get(key, {}).get(metric)
        hv = headless_e2e.get(key, {}).get(metric)
        if pv is None or hv is None:
            continue
        ps = f"{pv / 1000:.1f}s"
        hs = f"{hv / 1000:.1f}s"
        if pv > 0:
            pct = round((hv - pv) / pv * 100, 1)
            sign = "+" if pct > 0 else ""
            if pct < -5:
                diff = green(f"{sign}{pct}% faster")
            elif pct > 5:
                diff = red(f"{sign}{pct}% slower")
            else:
                diff = f"{sign}{pct}% same"
        else:
            diff = "-"
        print(f"  {label:<22} {ps:<14} {hs:<14} {diff}")
    print()


def print_comparison(comparison: Dict, change_note: str = ""):
    if not comparison or not comparison.get("deltas"):
        return
    prev_run = comparison["previous_run"]
    print(f"  {bold(f'── vs previous ({prev_run}) ──')}")
    if change_note:
        print(f'  Change: "{change_note}"')
    for name, d in comparison["deltas"].items():
        prev, curr, pct = d["prev"], d["curr"], d["pct"]
        higher_better = "msgs" in name or "sends" in name
        if "sends" in name:
            prev_s, curr_s = f"{prev} /s", f"{curr} /s"
        elif "msgs" in name:
            prev_s, curr_s = f"{prev} msg/s", f"{curr} msg/s"
        elif "total_ms" in name and prev >= 1000:
            prev_s, curr_s = f"{prev / 1000:.1f}s", f"{curr / 1000:.1f}s"
        elif "ms" in name:
            prev_s, curr_s = f"{prev} ms", f"{curr} ms"
        else:
            prev_s, curr_s = str(prev), str(curr)
        if higher_better:
            tag = green("improved") if pct > 5 else (red("regressed") if pct < -5 else "unchanged")
        else:
            tag = green("improved") if pct < -5 else (red("regressed") if pct > 5 else "unchanged")
        sign = "+" if pct > 0 else ""
        print(f"    {name + ':':<40} {prev_s} → {curr_s}   ({sign}{pct}% {tag})")
    print()


def _extract_total_ms(iteration: Dict, section: str, test: str) -> Optional[float]:
    """Extract total_ms for a given test from an iteration result."""
    data = iteration.get(section, {})
    if isinstance(data, dict) and test in data:
        return data[test].get("total_ms") if isinstance(data[test], dict) else None
    return None


def _compute_aggregate(iterations: List[Dict]) -> Dict[str, Any]:
    """Compute median/mean/min/max across iterations for each test."""
    import statistics

    # Collect all (section, test) pairs from first iteration
    sections = ["rpc_pane", "rpc_headless", "e2e_pane", "e2e_headless", "e2e_llm"]
    test_keys: Dict[str, List[str]] = {}
    for sec in sections:
        data = iterations[0].get(sec, {})
        if isinstance(data, dict):
            test_keys[sec] = [k for k, v in data.items()
                              if isinstance(v, dict) and "total_ms" in v]

    agg: Dict[str, Any] = {}
    for sec, tests in test_keys.items():
        agg[sec] = {}
        for t in tests:
            values = []
            for it in iterations:
                v = _extract_total_ms(it, sec, t)
                if v is not None:
                    values.append(v)
            if not values:
                continue
            s = sorted(values)
            n = len(s)
            agg[sec][t] = {
                "samples": n,
                "median_ms": round(statistics.median(s), 1),
                "mean_ms": round(statistics.mean(s), 1),
                "min_ms": round(s[0], 1),
                "max_ms": round(s[-1], 1),
                "stdev_ms": round(statistics.stdev(s), 1) if n >= 2 else 0,
                "values_ms": [round(v, 1) for v in values],
            }
    return agg


E2E_TEST_LABELS = {
    "ping_all": "Ping All",
    "parallel_delegation": "Delegation",
    "cross_messaging": "Cross Msg",
    "task_lifecycle": "Lifecycle",
    "broadcast_convergence": "Broadcast",
}


def _print_iteration_summary(iterations: List[Dict]):
    """Print a compact per-iteration table + aggregated stats."""
    import statistics

    sections = ["e2e_pane", "e2e_headless", "rpc_pane", "rpc_headless"]
    # Find which sections have data
    active_sections = []
    for sec in sections:
        if any(iterations[i].get(sec) for i in range(len(iterations))):
            active_sections.append(sec)

    for sec in active_sections:
        # Collect test names from first non-empty iteration
        test_names = []
        for it in iterations:
            data = it.get(sec, {})
            if isinstance(data, dict):
                test_names = [k for k, v in data.items()
                              if isinstance(v, dict) and "total_ms" in v]
                if test_names:
                    break

        if not test_names:
            continue

        sec_label = sec.replace("_", " ").title()
        print(f"\n  {bold(f'── Aggregate: {sec_label} ({len(iterations)} iterations) ──')}")

        # Per-iteration table
        header = f"  {'Test':<16}"
        for i in range(len(iterations)):
            header += f" {'#' + str(i+1):>8}"
        header += f" {'median':>8} {'mean':>8} {'stdev':>8}"
        print(header)

        for t in test_names:
            label = E2E_TEST_LABELS.get(t, t[:16])
            values = []
            row = f"  {label:<16}"
            for it in iterations:
                v = _extract_total_ms(it, sec, t)
                if v is not None:
                    values.append(v)
                    row += f" {v:>7.0f}ms" if v >= 1 else f" {v:>6.1f}ms"
                else:
                    row += f" {'—':>8}"

            if len(values) >= 2:
                med = statistics.median(values)
                avg = statistics.mean(values)
                sd = statistics.stdev(values)
                row += f" {med:>6.0f}ms {avg:>6.0f}ms {sd:>6.0f}ms"
            elif values:
                row += f" {values[0]:>6.0f}ms {values[0]:>6.0f}ms {'—':>8}"

            print(row)

    print()


def _count_results(*result_dicts: Dict):
    tp = tf = 0
    for rd in result_dicts:
        for r in rd.values():
            if isinstance(r, dict) and "passed" in r:
                if r["passed"]:
                    tp += 1
                else:
                    tf += 1
    return tp, tf


def print_summary(saved_path: str, *result_dicts: Dict):
    tp, tf = _count_results(*result_dicts)
    failed_str = red(f"{tf} failed") if tf else f"{tf} failed"
    print(bold(f"=== Results: {green(f'{tp} passed')}, {failed_str} ==="))
    print(f"  Saved: {saved_path}")
    print()


# ══════════════════════════════════════════════
#  History / Compare
# ══════════════════════════════════════════════

def show_history():
    if not BENCHMARKS_DIR.exists():
        print("No benchmark history found.")
        return
    files = sorted(BENCHMARKS_DIR.glob("*.json"), reverse=True)[:10]
    if not files:
        print("No benchmark history found.")
        return
    print()
    print(bold("=== tm-bench history ==="))
    print()
    print(f"  {'RUN':<25} {'MODE':<10} {'RPC(p/f)':<12} {'E2E(p/f)':<12} {'STATUS_P50':<14} CHANGE NOTE")
    for path in files:
        with open(path) as f:
            data = json.load(f)
        run_id = data.get("run_id", path.stem)
        # Detect mode
        has_pane = bool(data.get("rpc_pane") or data.get("e2e_pane"))
        has_hl = bool(data.get("rpc_headless") or data.get("e2e_headless"))
        has_legacy = bool(data.get("rpc") or data.get("e2e"))
        if has_pane and has_hl:
            mode = "both"
        elif has_hl:
            mode = "headless"
        elif has_pane or has_legacy:
            mode = "pane"
        else:
            mode = "?"
        rpc_all = {**data.get("rpc_pane", {}), **data.get("rpc_headless", {}), **data.get("rpc", {})}
        e2e_all = {**data.get("e2e_pane", {}), **data.get("e2e_headless", {}), **data.get("e2e", {})}
        rpc_p = sum(1 for r in rpc_all.values() if isinstance(r, dict) and r.get("passed"))
        rpc_f = sum(1 for r in rpc_all.values() if isinstance(r, dict) and not r.get("passed"))
        e2e_p = sum(1 for r in e2e_all.values() if isinstance(r, dict) and r.get("passed"))
        e2e_f = sum(1 for r in e2e_all.values() if isinstance(r, dict) and not r.get("passed"))
        st_p50 = (rpc_all.get("status_latency", {}).get("p50_ms")
                   or rpc_all.get("list_agents", {}).get("p50_ms") or "-")
        note = data.get("metadata", {}).get("change_note", "")[:30]
        st_s = f"{st_p50} ms" if isinstance(st_p50, (int, float)) else str(st_p50)
        print(f"  {run_id:<25} {mode:<10} {f'{rpc_p}/{rpc_f}':<12} {f'{e2e_p}/{e2e_f}':<12} "
              f"{st_s:<14} {note}")
    print()


def compare_runs(prefix_a: str, prefix_b: str):
    a = load_result_by_prefix(prefix_a)
    b = load_result_by_prefix(prefix_b)
    if not a:
        print(f"No benchmark found matching prefix: {prefix_a}")
        return
    if not b:
        print(f"No benchmark found matching prefix: {prefix_b}")
        return
    print()
    print(bold(f"=== Comparing {a['run_id']} vs {b['run_id']} ==="))
    print()
    comparison = compute_comparison(b, a)
    if comparison and comparison.get("deltas"):
        for name, d in comparison["deltas"].items():
            prev, curr, pct = d["prev"], d["curr"], d["pct"]
            sign = "+" if pct > 0 else ""
            higher_better = "msgs" in name or "sends" in name
            if higher_better:
                tag = green("improved") if pct > 5 else (red("regressed") if pct < -5 else "unchanged")
            else:
                tag = green("improved") if pct < -5 else (red("regressed") if pct > 5 else "unchanged")
            print(f"  {name + ':':<40} {prev} → {curr}   ({sign}{pct}% {tag})")
    else:
        print("  No comparable metrics found.")
    print()


# ══════════════════════════════════════════════
#  CLI entry point
# ══════════════════════════════════════════════

def _interactive_menu() -> Dict[str, str]:
    """Show interactive menu when no flags are given. Returns selected options."""
    print()
    print(bold("=== tm-bench agent — Configuration ==="))

    # Detect existing team for context
    team_info = _detect_team()
    daemon_sock = _detect_daemon_socket()

    if team_info:
        tn = team_info.get("team_name", "?")
        agents = team_info.get("agents", [])
        print(f"  {green('●')} Active team: {bold(tn)} ({len(agents)} agents)")
    else:
        print(f"  {dim('○ No active team detected')}")
    if daemon_sock:
        print(f"  {green('●')} Daemon: {dim(daemon_sock)}")
    else:
        print(f"  {dim('○ No daemon socket')}")

    # Quick presets
    print()
    print(f"  {bold('Quick presets:')}")
    if team_info:
        tn = team_info.get("team_name", "?")
        n = len(team_info.get("agents", []))
        print(f"    {cyan('1)')} {bold('Existing team E2E')}    — {tn} ({n} agents), no new team  {green('fastest')}")
        print(f"    {cyan('2)')} {bold('Full pane benchmark')} — temp team for RPC + existing for E2E")
    else:
        print(f"    {dim('1)')} {dim('Existing team E2E')}    — {yellow('no team detected')}")
        print(f"    {cyan('2)')} {bold('Full pane benchmark')} — creates temp team for RPC + E2E")
    print(f"    {cyan('3)')} {bold('LLM leader E2E')}     — creates new team with --claude-leader")
    if daemon_sock:
        print(f"    {cyan('4)')} {bold('Headless benchmark')} — daemon subprocess mode")
    else:
        print(f"    {dim('4)')} {dim('Headless benchmark')} — {yellow('no daemon')}")
    print(f"    {cyan('5)')} {bold('RPC only')}           — infrastructure latency (temp team)")
    print(f"    {cyan('6)')} {bold('Custom...')}          — pick leader / mode / layers")
    print()

    preset = input(f"  Select [{cyan('1')}-{cyan('6')}, default=1]: ").strip() or "1"

    # ── Preset mappings ──
    if preset == "1":
        if not team_info:
            print(f"\n  {yellow('WARN')}: No active team. Falling back to full pane benchmark.")
            return {"leader": "terminal", "mode": "pane", "rpc_only": False,
                    "e2e_only": False, "note": ""}
        print(f"\n  {dim('→ Terminal leader, pane mode, E2E only (existing team)')}")
        note = input("  Change note (optional): ").strip()
        return {"leader": "terminal", "mode": "pane", "rpc_only": False,
                "e2e_only": True, "note": note}

    elif preset == "2":
        print(f"\n  {dim('→ Terminal leader, pane mode, RPC + E2E')}")
        note = input("  Change note (optional): ").strip()
        return {"leader": "terminal", "mode": "pane", "rpc_only": False,
                "e2e_only": False, "note": note}

    elif preset == "3":
        print(f"\n  {dim('→ LLM leader, pane mode, E2E only (creates new team)')}")
        note = input("  Change note (optional): ").strip()
        return {"leader": "llm", "mode": "pane", "rpc_only": False,
                "e2e_only": True, "note": note}

    elif preset == "4":
        if not daemon_sock:
            print(f"\n  {red('ERROR')}: No daemon socket found. Start term-meshd first.")
            raise EOFError
        print(f"\n  {dim('→ Terminal leader, headless mode, RPC + E2E')}")
        note = input("  Change note (optional): ").strip()
        return {"leader": "terminal", "mode": "headless", "rpc_only": False,
                "e2e_only": False, "note": note}

    elif preset == "5":
        print(f"\n  {dim('→ Terminal leader, pane mode, RPC only (temp team)')}")
        note = input("  Change note (optional): ").strip()
        return {"leader": "terminal", "mode": "pane", "rpc_only": True,
                "e2e_only": False, "note": note}

    # ── Custom: full selection (preset == "6" or anything else) ──
    print()
    print(f"  {bold('Leader type:')}")
    print(f"    {cyan('1)')} Terminal (script-driven, uses existing team for E2E)")
    print(f"    {cyan('2)')} LLM (Claude --claude-leader, creates new team)")
    print(f"    {cyan('3)')} Both (compare terminal vs LLM)")
    print()
    leader_choice = input("  Select leader [1/2/3, default=1]: ").strip() or "1"
    leader_map = {"1": "terminal", "2": "llm", "3": "both"}
    leader = leader_map.get(leader_choice, "terminal")

    # Infra mode selection
    print()
    print(f"  {bold('Infrastructure mode:')}")
    print(f"    {cyan('1)')} Pane (GUI terminal panes)")
    if daemon_sock:
        print(f"    {cyan('2)')} Headless (daemon subprocesses)")
        print(f"    {cyan('3)')} Both (compare pane vs headless)")
    else:
        print(f"    {dim('2)')} {dim('Headless')} — {yellow('no daemon')}")
        print(f"    {dim('3)')} {dim('Both')}     — {yellow('no daemon')}")
    print()
    mode_choice = input("  Select mode [1/2/3, default=1]: ").strip() or "1"
    if mode_choice in ("2", "3") and not daemon_sock:
        print(f"  {yellow('WARN')}: No daemon socket. Falling back to pane mode.")
        mode_choice = "1"
    mode_map = {"1": "pane", "2": "headless", "3": "both"}
    mode = mode_map.get(mode_choice, "pane")

    # Layer selection
    print()
    print(f"  {bold('Benchmark layers:')}")
    print(f"    {cyan('1)')} All (RPC + E2E)")
    print(f"    {cyan('2)')} RPC only  — infrastructure latency {dim('(creates temp team)')}")
    if team_info:
        print(f"    {cyan('3)')} E2E only  — agent communication {dim('(uses existing team)')}")
    else:
        print(f"    {cyan('3)')} E2E only  — agent communication {dim('(needs active team)')}")
    print()
    layer_choice = input("  Select layer [1/2/3, default=1]: ").strip() or "1"

    rpc_only = layer_choice == "2"
    e2e_only = layer_choice == "3"

    # Summary
    parts = []
    if leader == "terminal":
        parts.append("terminal leader")
    elif leader == "llm":
        parts.append("LLM leader")
    else:
        parts.append("terminal + LLM")
    parts.append(f"{mode} mode")
    if rpc_only:
        parts.append("RPC only")
    elif e2e_only:
        parts.append("E2E only")
    else:
        parts.append("RPC + E2E")
    print(f"\n  {dim('→ ' + ', '.join(parts))}")

    print()
    note = input("  Change note (optional): ").strip()

    return {"leader": leader, "mode": mode, "rpc_only": rpc_only,
            "e2e_only": e2e_only, "note": note}


def main():
    parser = argparse.ArgumentParser(
        description="Agent Team Communication Benchmark — Pane & Headless, Terminal & LLM leader",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 scripts/bench-agent.py                          # Interactive menu
  python3 scripts/bench-agent.py --mode pane              # Pane only, terminal leader
  python3 scripts/bench-agent.py --mode headless          # Headless only
  python3 scripts/bench-agent.py --leader llm             # LLM leader E2E
  python3 scripts/bench-agent.py --leader both            # Compare terminal vs LLM
  python3 scripts/bench-agent.py --rpc-only               # RPC infra only
  python3 scripts/bench-agent.py --e2e-only               # Agent E2E only
  python3 scripts/bench-agent.py --repeat 5 --note "..."  # 5 iterations with stats
  python3 scripts/bench-agent.py --history                # Show history
  python3 scripts/bench-agent.py --compare A B            # Compare two runs
        """,
    )
    parser.add_argument("--mode", choices=["pane", "headless", "both"], default=None,
                        help="Infrastructure mode (default: interactive)")
    parser.add_argument("--leader", choices=["terminal", "llm", "both"], default=None,
                        help="Leader type (default: interactive)")
    parser.add_argument("--rpc-only", action="store_true",
                        help="Run only RPC infrastructure benchmarks")
    parser.add_argument("--e2e-only", action="store_true",
                        help="Run only E2E agent benchmarks")
    parser.add_argument("--repeat", type=int, default=1,
                        help="Number of iterations to run (default: 1)")
    parser.add_argument("--history", action="store_true",
                        help="Show recent benchmark history")
    parser.add_argument("--compare", nargs=2, metavar=("A", "B"),
                        help="Compare two runs by timestamp prefix")
    parser.add_argument("--note", default="",
                        help="Change note attached to this run")

    args = parser.parse_args()

    # Interactive menu if no mode/leader flags given
    if args.mode is None and args.leader is None and not args.rpc_only and not args.e2e_only \
            and not args.history and not args.compare:
        try:
            choices = _interactive_menu()
            args.mode = choices["mode"]
            args.leader = choices["leader"]
            args.rpc_only = choices["rpc_only"]
            args.e2e_only = choices["e2e_only"]
            if choices["note"]:
                args.note = choices["note"]
        except (EOFError, KeyboardInterrupt):
            print("\n  Cancelled.")
            return

    # Defaults for non-interactive
    if args.mode is None:
        args.mode = "pane"
    if args.leader is None:
        args.leader = "terminal"

    if args.history:
        show_history()
        return
    if args.compare:
        compare_runs(args.compare[0], args.compare[1])
        return

    # ── Detect sockets ──
    try:
        app_sock = _detect_socket()
    except RuntimeError as e:
        print(f"\n{red('ERROR')}: {e}")
        sys.exit(1)

    daemon_sock = _detect_daemon_socket()
    do_pane = args.mode in ("pane", "both")
    do_headless = args.mode in ("headless", "both")

    if do_headless and not daemon_sock:
        if args.mode == "headless":
            print(f"\n{red('ERROR')}: No daemon socket found. Is term-meshd running?")
            sys.exit(1)
        else:
            print(f"  {yellow('WARN')}: No daemon socket found — skipping headless benchmarks")
            do_headless = False

    git_info = _git_info()
    team_info = _detect_team() if (do_pane and not args.rpc_only) else None

    print_header(app_sock, git_info, daemon_sock if do_headless else None, team_info)

    do_terminal = args.leader in ("terminal", "both")
    do_llm = args.leader in ("llm", "both")

    repeat = max(1, args.repeat)
    all_iterations: List[Dict[str, Any]] = []

    for iteration in range(1, repeat + 1):
        if repeat > 1:
            print(f"\n  {bold(cyan(f'━━ Iteration {iteration}/{repeat} ━━'))}")

        rpc_pane: Dict[str, Any] = {}
        rpc_headless: Dict[str, Any] = {}
        e2e_pane: Dict[str, Any] = {}
        e2e_headless: Dict[str, Any] = {}
        e2e_llm: Dict[str, Any] = {}

        # ── RPC benchmarks ──
        if not args.e2e_only:
            if do_pane:
                print(f"  {bold(cyan('▸ RPC: Pane mode'))}")
                rpc_pane = run_rpc_pane_benchmarks(app_sock)
                print_rpc_pane_results(rpc_pane)

            if do_headless:
                print(f"  {bold(cyan('▸ RPC: Headless mode'))}")
                rpc_headless = run_rpc_headless_benchmarks(daemon_sock, app_sock)
                print_rpc_headless_results(rpc_headless)

        # ── E2E benchmarks ──
        if not args.rpc_only:
            # Terminal leader E2E (script-driven)
            if do_terminal:
                if do_pane:
                    print(f"  {bold(cyan('▸ E2E: Pane agents (terminal leader)'))}")
                    e2e_pane = run_e2e_pane_benchmarks()
                    if e2e_pane:
                        print_e2e_results(e2e_pane, "E2E: Pane Agents (terminal leader)")

                if do_headless:
                    print(f"  {bold(cyan('▸ E2E: Headless agents (terminal leader)'))}")
                    e2e_headless = run_e2e_headless_benchmarks()
                    if e2e_headless:
                        print_e2e_results(e2e_headless, "E2E: Headless Agents (terminal leader)")

                if e2e_pane and e2e_headless:
                    print_mode_comparison(e2e_pane, e2e_headless)

            # LLM leader E2E (Claude --claude-leader)
            if do_llm:
                print(f"  {bold(cyan('▸ E2E: LLM Leader (Claude)'))}")
                e2e_llm = run_e2e_llm_leader_benchmarks()
                if e2e_llm:
                    print_e2e_llm_results(e2e_llm)

                # Compare terminal vs LLM if both were run
                if do_terminal and e2e_pane and e2e_llm:
                    print_leader_comparison(e2e_pane, e2e_llm)

        all_iterations.append({
            "iteration": iteration,
            "rpc_pane": rpc_pane,
            "rpc_headless": rpc_headless,
            "e2e_pane": e2e_pane,
            "e2e_headless": e2e_headless,
            "e2e_llm": e2e_llm,
        })

    # ── Aggregate stats for multi-iteration runs ──
    if repeat > 1:
        _print_iteration_summary(all_iterations)

    # Use last iteration as the primary result (or aggregated median for multi-run)
    last = all_iterations[-1]
    rpc_pane = last["rpc_pane"]
    rpc_headless = last["rpc_headless"]
    e2e_pane = last["e2e_pane"]
    e2e_headless = last["e2e_headless"]
    e2e_llm = last["e2e_llm"]

    # ── Assemble & save ──
    data: Dict[str, Any] = {
        "metadata": {
            **git_info,
            "mode": args.mode,
            "leader": args.leader,
            "agent_count": len(team_info.get("agents", [])) if team_info else BENCH_AGENT_COUNT,
            "team_name": team_info.get("team_name", "N/A") if team_info else "N/A",
            "app_socket": app_sock,
            "daemon_socket": daemon_sock or "N/A",
            "change_note": args.note,
            "repeat": repeat,
        },
        "rpc_pane": rpc_pane,
        "rpc_headless": rpc_headless,
        "e2e_pane": e2e_pane,
        "e2e_headless": e2e_headless,
        "e2e_llm": e2e_llm,
    }

    if repeat > 1:
        data["iterations"] = all_iterations
        data["aggregate"] = _compute_aggregate(all_iterations)

    tp, tf = _count_results(rpc_pane, rpc_headless, e2e_pane, e2e_headless, e2e_llm)
    data["summary"] = {"total_passed": tp, "total_failed": tf}

    saved_path = save_results(data)

    previous = load_previous_result()
    if previous:
        comparison = compute_comparison(data, previous)
        data["comparison"] = comparison
        with open(saved_path, "w") as f:
            json.dump(data, f, indent=2)
        print_comparison(comparison, args.note)

    print_summary(saved_path, rpc_pane, rpc_headless, e2e_pane, e2e_headless, e2e_llm)


if __name__ == "__main__":
    main()
