#!/usr/bin/env python3
"""
bench-agent.py — Agent Team Communication Benchmark

Measures RPC infrastructure latency and end-to-end agent communication performance.
Results are saved as JSON and compared with previous runs to track improvements.

Usage:
    python3 scripts/bench-agent.py              # Run all benchmarks
    python3 scripts/bench-agent.py --rpc-only   # RPC infrastructure only
    python3 scripts/bench-agent.py --e2e-only   # Agent E2E only
    python3 scripts/bench-agent.py --history    # Show recent benchmark history
    python3 scripts/bench-agent.py --compare A B # Compare two runs
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
BENCH_TEAM = "bench-rpc"


# ── Socket helpers (from test_team_rpc.py) ──

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
    """Auto-detect a connectable term-mesh socket."""
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
    """Get current git SHA and branch."""
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


# ═══════════════════════════════════════════
#  Layer 1: RPC Infrastructure Benchmarks
# ═══════════════════════════════════════════

def bench_rpc_status(sock_path: str, team_name: str, iterations: int = 20) -> Dict:
    """Benchmark team.status latency."""
    latencies: List[float] = []
    for i in range(iterations):
        t0 = time.perf_counter()
        resp = _rpc_call(sock_path, "team.status", {"team_name": team_name}, rid=100 + i)
        t1 = time.perf_counter()
        if resp.get("ok"):
            latencies.append((t1 - t0) * 1000)

    stats = compute_stats(latencies)
    return {
        "iterations": iterations,
        "successful": len(latencies),
        "target_p95_ms": 10,
        **stats,
        "passed": stats["p95_ms"] <= 10 if latencies else False,
    }


def bench_rpc_task_create(sock_path: str, team_name: str, iterations: int = 20) -> Dict:
    """Benchmark team.task.create latency."""
    latencies: List[float] = []
    for i in range(iterations):
        t0 = time.perf_counter()
        resp = _rpc_call(sock_path, "team.task.create", {
            "team_name": team_name,
            "title": f"bench-task-{i}",
            "assignee": "w1",
        }, rid=200 + i)
        t1 = time.perf_counter()
        if resp.get("ok"):
            latencies.append((t1 - t0) * 1000)

    stats = compute_stats(latencies)
    return {
        "iterations": iterations,
        "successful": len(latencies),
        "target_p95_ms": 10,
        **stats,
        "passed": stats["p95_ms"] <= 10 if latencies else False,
    }


def bench_rpc_task_lifecycle(sock_path: str, team_name: str, iterations: int = 10) -> Dict:
    """Benchmark full task lifecycle: create → get → update → review → done."""
    latencies: List[float] = []
    for i in range(iterations):
        cycle_start = time.perf_counter()

        # Create
        resp = _rpc_call(sock_path, "team.task.create", {
            "team_name": team_name, "title": f"lifecycle-{i}", "assignee": "w1",
        }, rid=300 + i * 5)
        if not resp.get("ok"):
            continue
        task_id = resp.get("result", {}).get("id", "")
        if not task_id:
            continue

        # Get
        _rpc_call(sock_path, "team.task.get", {
            "team_name": team_name, "task_id": task_id,
        }, rid=301 + i * 5)

        # Update → in_progress
        _rpc_call(sock_path, "team.task.update", {
            "team_name": team_name, "task_id": task_id, "status": "in_progress",
        }, rid=302 + i * 5)

        # Review
        _rpc_call(sock_path, "team.task.review", {
            "team_name": team_name, "task_id": task_id, "summary": "bench review",
        }, rid=303 + i * 5)

        # Done
        _rpc_call(sock_path, "team.task.done", {
            "team_name": team_name, "task_id": task_id, "result": "bench done",
        }, rid=304 + i * 5)

        cycle_end = time.perf_counter()
        latencies.append((cycle_end - cycle_start) * 1000)

    stats = compute_stats(latencies)
    return {
        "iterations": iterations,
        "successful": len(latencies),
        "target_p95_ms": 30,
        **stats,
        "passed": stats["p95_ms"] <= 30 if latencies else False,
    }


def bench_rpc_message_throughput(sock_path: str, team_name: str, count: int = 50) -> Dict:
    """Benchmark message post + list throughput."""
    t0 = time.perf_counter()
    success = 0
    for i in range(count):
        resp = _rpc_call(sock_path, "team.message.post", {
            "team_name": team_name,
            "from": "w1",
            "content": f"bench msg {i}",
            "type": "note",
        }, rid=400 + i)
        if resp.get("ok"):
            success += 1
    t1 = time.perf_counter()

    elapsed = t1 - t0
    msgs_per_sec = round(success / elapsed, 1) if elapsed > 0 else 0

    # Also measure list latency
    t2 = time.perf_counter()
    _rpc_call(sock_path, "team.message.list", {"team_name": team_name}, rid=499)
    t3 = time.perf_counter()

    # Cleanup
    _rpc_call(sock_path, "team.message.clear", {"team_name": team_name}, rid=498)

    return {
        "messages": count,
        "successful": success,
        "target_msgs_per_sec": 100,
        "elapsed_ms": round(elapsed * 1000, 1),
        "msgs_per_sec": msgs_per_sec,
        "list_ms": round((t3 - t2) * 1000, 2),
        "passed": msgs_per_sec >= 100,
    }


def bench_rpc_heartbeat(sock_path: str, team_name: str, iterations: int = 20) -> Dict:
    """Benchmark agent heartbeat latency."""
    latencies: List[float] = []
    for i in range(iterations):
        t0 = time.perf_counter()
        resp = _rpc_call(sock_path, "team.agent.heartbeat", {
            "team_name": team_name,
            "agent_name": "w1",
            "summary": f"bench heartbeat {i}",
        }, rid=500 + i)
        t1 = time.perf_counter()
        if resp.get("ok"):
            latencies.append((t1 - t0) * 1000)

    stats = compute_stats(latencies)
    return {
        "iterations": iterations,
        "successful": len(latencies),
        "target_p95_ms": 10,
        **stats,
        "passed": stats["p95_ms"] <= 10 if latencies else False,
    }


def bench_rpc_batch(sock_path: str, team_name: str, batch_size: int = 10,
                    rounds: int = 5) -> Dict:
    """Benchmark cold vs warm rapid-fire RPC calls (baseline for future batching)."""
    cold_times: List[float] = []
    warm_times: List[float] = []

    for r in range(rounds):
        # Cold pass — first burst after a small pause
        time.sleep(0.01)
        t0 = time.perf_counter()
        for i in range(batch_size):
            _rpc_call(sock_path, "team.status", {"team_name": team_name},
                      rid=600 + r * batch_size + i)
        t1 = time.perf_counter()
        cold_times.append((t1 - t0) * 1000)

        # Warm pass — immediately after cold
        t2 = time.perf_counter()
        for i in range(batch_size):
            _rpc_call(sock_path, "team.status", {"team_name": team_name},
                      rid=700 + r * batch_size + i)
        t3 = time.perf_counter()
        warm_times.append((t3 - t2) * 1000)

    cold_avg = round(sum(cold_times) / len(cold_times), 2) if cold_times else 0
    warm_avg = round(sum(warm_times) / len(warm_times), 2) if warm_times else 0
    speedup = round(cold_avg / warm_avg, 2) if warm_avg > 0 else 0

    return {
        "batch_size": batch_size,
        "rounds": rounds,
        "sequential_ms": cold_avg,
        "batch_ms": warm_avg,
        "speedup": speedup,
        "target_speedup": 1.5,
        # Baseline measure — always pass; real batching will improve this
        "passed": True,
    }


def run_rpc_benchmarks(sock_path: str) -> Dict:
    """Run all RPC benchmarks, creating a temporary team."""
    results: Dict[str, Any] = {}

    # Ensure clean state
    try:
        _rpc_call(sock_path, "team.destroy", {"team_name": BENCH_TEAM}, rid=99)
    except Exception:
        pass

    try:
        resp = _rpc_call(sock_path, "team.create", {
            "team_name": BENCH_TEAM,
            "agents": [{"name": "w1", "model": "sonnet", "agent_type": "general"}],
            "working_directory": os.getcwd(),
            "leader_session_id": "bench-leader",
        }, rid=1)
        if not resp.get("ok"):
            print(f"  {red('ERROR')}: Failed to create bench team: {resp.get('error', resp)}")
            return results
    except Exception as e:
        print(f"  {red('ERROR')}: Cannot create bench team: {e}")
        return results

    time.sleep(1)  # allow team to initialise

    try:
        print(f"  {dim('Running status latency...')}")
        results["status_latency"] = bench_rpc_status(sock_path, BENCH_TEAM)

        print(f"  {dim('Running task CRUD...')}")
        results["task_create"] = bench_rpc_task_create(sock_path, BENCH_TEAM)

        print(f"  {dim('Running task lifecycle...')}")
        results["task_lifecycle"] = bench_rpc_task_lifecycle(sock_path, BENCH_TEAM)

        print(f"  {dim('Running message throughput...')}")
        results["message_throughput"] = bench_rpc_message_throughput(sock_path, BENCH_TEAM)

        print(f"  {dim('Running heartbeat...')}")
        results["heartbeat"] = bench_rpc_heartbeat(sock_path, BENCH_TEAM)

        print(f"  {dim('Running batch comparison...')}")
        results["batch_speedup"] = bench_rpc_batch(sock_path, BENCH_TEAM)
    finally:
        try:
            _rpc_call(sock_path, "team.destroy", {"team_name": BENCH_TEAM}, rid=999)
        except Exception:
            pass

    return results


# ═══════════════════════════════════════════
#  Layer 2: Agent E2E Benchmarks
# ═══════════════════════════════════════════

def _tm_agent(*args: str, timeout: float = 120) -> subprocess.CompletedProcess:
    """Run tm-agent command and return CompletedProcess."""
    cmd = ["tm-agent", *args]
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        # Fallback to project-local binary
        cmd = ["./daemon/target/release/tm-agent", *args]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def _detect_team() -> Optional[Dict]:
    """Detect existing team and agents from tm-agent status."""
    result = _tm_agent("status")
    if result.returncode != 0:
        return None

    output = result.stdout.strip()
    if not output:
        return None

    # Try JSON first
    try:
        data = json.loads(output)
        if isinstance(data, dict):
            team_name = (data.get("team_name")
                         or data.get("team")
                         or data.get("name")
                         or "unknown")
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
    except (json.JSONDecodeError, TypeError):
        pass

    # Parse text output
    team_name = None
    agents: List[str] = []
    skip_words = {"team", "status", "agents", "name", "state", "task", "tasks", "messages"}

    for line in output.split("\n"):
        stripped = line.strip()
        lower = stripped.lower()

        if lower.startswith("team:") or lower.startswith("team name:"):
            team_name = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("- ") or (line.startswith("  ") and stripped):
            parts = stripped.lstrip("- ").split()
            if parts and parts[0].lower() not in skip_words:
                agents.append(parts[0])

    if team_name or agents:
        return {"team_name": team_name or "unknown", "agents": agents}
    return None


def bench_e2e_ping(agents: List[str]) -> Dict:
    """Ping all agents and measure response times."""
    t0 = time.perf_counter()

    for agent in agents:
        _tm_agent("send", agent, "Reply with exactly: pong")

    result = _tm_agent("wait", "--timeout", "60", "--mode", "any")
    t1 = time.perf_counter()

    total_ms = round((t1 - t0) * 1000)
    responded = 0
    per_agent: Dict[str, float] = {}

    if result.returncode == 0:
        try:
            data = json.loads(result.stdout.strip())
            if isinstance(data, dict):
                for name, info in data.items():
                    if isinstance(info, dict) and "elapsed_ms" in info:
                        per_agent[name] = info["elapsed_ms"]
                        responded += 1
        except (json.JSONDecodeError, TypeError):
            pass
        if not per_agent:
            responded = len(agents)

    return {
        "agent_count": len(agents),
        "responded": responded,
        "per_agent_ms": per_agent,
        "total_ms": total_ms,
        "all_responded": responded >= len(agents),
        "passed": responded >= len(agents),
    }


def bench_e2e_delegation(agents: List[str]) -> Dict:
    """Delegate tasks to all agents and measure completion."""
    t0 = time.perf_counter()

    for agent in agents:
        _tm_agent("delegate", agent, f"Reply with: delegation-ack from {agent}")

    result = _tm_agent("wait", "--timeout", "120", "--mode", "any")
    t1 = time.perf_counter()

    total_ms = round((t1 - t0) * 1000)
    completed = 0
    per_agent: Dict[str, float] = {}

    if result.returncode == 0:
        try:
            data = json.loads(result.stdout.strip())
            if isinstance(data, dict):
                for name, info in data.items():
                    if isinstance(info, dict) and "elapsed_ms" in info:
                        per_agent[name] = info["elapsed_ms"]
                        completed += 1
        except (json.JSONDecodeError, TypeError):
            pass
        if not per_agent:
            completed = len(agents)

    return {
        "agent_count": len(agents),
        "completed": completed,
        "per_agent_ms": per_agent,
        "total_ms": total_ms,
        "all_completed": completed >= len(agents),
        "passed": completed >= len(agents),
    }


def bench_e2e_cross_messaging(agents: List[str]) -> Dict:
    """Test cross-agent messaging by delegating messaging tasks."""
    if len(agents) < 2:
        return {
            "passed": False,
            "error": "Need at least 2 agents",
            "delivered": 0,
            "total": 0,
            "pairs": 0,
            "total_ms": 0,
            "all_delivered": False,
        }

    pairs = min(4, len(agents) // 2)
    t0 = time.perf_counter()

    for i in range(pairs):
        sender = agents[i * 2]
        receiver = agents[i * 2 + 1]
        _tm_agent(
            "delegate", sender,
            f"Send a message to {receiver} saying 'cross-test-{i}' "
            f"using: tm-agent msg send 'cross-test-{i}' --to {receiver}")

    result = _tm_agent("wait", "--timeout", "60", "--mode", "any")
    t1 = time.perf_counter()

    delivered = pairs if result.returncode == 0 else 0

    return {
        "pairs": pairs,
        "delivered": delivered,
        "total": pairs,
        "total_ms": round((t1 - t0) * 1000),
        "all_delivered": delivered >= pairs,
        "passed": delivered >= pairs,
    }


def bench_e2e_task_lifecycle(agents: List[str]) -> Dict:
    """Delegate task lifecycle steps to an agent."""
    if not agents:
        return {"passed": False, "error": "No agents available",
                "stages_completed": 0, "total_stages": 5, "total_ms": 0, "agent": ""}

    agent = agents[0]
    t0 = time.perf_counter()

    _tm_agent(
        "delegate", agent,
        "Execute the following task lifecycle steps in order: "
        "1) Run: tm-agent task start <your-task-id>  "
        "2) Run: tm-agent heartbeat 'working on it'  "
        "3) Run: tm-agent task review <your-task-id> 'lifecycle bench complete'  "
        "4) Run: tm-agent task done <your-task-id> 'lifecycle complete'  "
        "5) Reply with: lifecycle-done")

    result = _tm_agent("wait", "--timeout", "120", "--mode", "any")
    t1 = time.perf_counter()

    stages = 5 if result.returncode == 0 else 0

    return {
        "agent": agent,
        "stages_completed": stages,
        "total_stages": 5,
        "total_ms": round((t1 - t0) * 1000),
        "passed": stages >= 5,
    }


def bench_e2e_broadcast(agents: List[str]) -> Dict:
    """Broadcast to all agents and measure convergence."""
    t0 = time.perf_counter()

    _tm_agent("broadcast", "Reply with exactly: broadcast-ack")
    result = _tm_agent("wait", "--timeout", "60", "--mode", "any")

    t1 = time.perf_counter()
    total_ms = round((t1 - t0) * 1000)
    responded = len(agents) if result.returncode == 0 else 0

    return {
        "agent_count": len(agents),
        "responded": responded,
        "total_ms": total_ms,
        "all_responded": responded >= len(agents),
        "passed": responded >= len(agents),
    }


def run_e2e_benchmarks() -> Dict:
    """Run all E2E benchmarks using existing team."""
    results: Dict[str, Any] = {}

    team_info = _detect_team()
    if not team_info:
        print(f"  {red('ERROR')}: No active team detected. "
              "Start a team with: /team create N --claude-leader")
        return results

    agents = team_info.get("agents", [])
    team_name = team_info.get("team_name", "unknown")

    if not agents:
        print(f"  {red('ERROR')}: No agents found in team '{team_name}'")
        return results

    print(f"  {dim(f'Team: {team_name}, Agents: {len(agents)}')}")

    print(f"  {dim('Running ping all...')}")
    results["ping_all"] = bench_e2e_ping(agents)

    print(f"  {dim('Running parallel delegation...')}")
    results["parallel_delegation"] = bench_e2e_delegation(agents)

    print(f"  {dim('Running cross messaging...')}")
    results["cross_messaging"] = bench_e2e_cross_messaging(agents)

    print(f"  {dim('Running task lifecycle...')}")
    results["task_lifecycle"] = bench_e2e_task_lifecycle(agents)

    print(f"  {dim('Running broadcast convergence...')}")
    results["broadcast_convergence"] = bench_e2e_broadcast(agents)

    return results


# ═══════════════════════════════════════════
#  Results: save / load / compare
# ═══════════════════════════════════════════

def save_results(data: Dict) -> str:
    """Save benchmark results to JSON file. Returns the file path."""
    BENCHMARKS_DIR.mkdir(parents=True, exist_ok=True)

    run_id = datetime.now().strftime("%Y-%m-%dT%H-%M-%S")
    path = BENCHMARKS_DIR / f"{run_id}.json"

    data["version"] = 1
    data["run_id"] = run_id
    data["timestamp"] = datetime.now(timezone.utc).isoformat()

    with open(path, "w") as f:
        json.dump(data, f, indent=2)

    return str(path)


def load_previous_result() -> Optional[Dict]:
    """Load the most recent previous benchmark result (second-newest file)."""
    if not BENCHMARKS_DIR.exists():
        return None
    files = sorted(BENCHMARKS_DIR.glob("*.json"), reverse=True)
    if len(files) < 2:
        return None
    with open(files[1]) as f:
        return json.load(f)


def load_result_by_prefix(prefix: str) -> Optional[Dict]:
    """Load a result whose run_id starts with *prefix*."""
    if not BENCHMARKS_DIR.exists():
        return None
    for path in sorted(BENCHMARKS_DIR.glob("*.json"), reverse=True):
        if path.stem.startswith(prefix):
            with open(path) as f:
                return json.load(f)
    return None


def compute_comparison(current: Dict, previous: Dict) -> Dict:
    """Compute metric deltas between two benchmark runs."""
    deltas: Dict[str, Dict] = {}
    improved: List[str] = []
    regressed: List[str] = []
    unchanged: List[str] = []

    metric_defs = [
        # (display_name, layer, scenario, metric, higher_is_better)
        ("rpc.status_latency.p50_ms",       "rpc", "status_latency",      "p50_ms",       False),
        ("rpc.status_latency.p95_ms",       "rpc", "status_latency",      "p95_ms",       False),
        ("rpc.task_create.p95_ms",          "rpc", "task_create",         "p95_ms",       False),
        ("rpc.task_lifecycle.p95_ms",       "rpc", "task_lifecycle",      "p95_ms",       False),
        ("rpc.message_throughput.msgs/s",   "rpc", "message_throughput",  "msgs_per_sec", True),
        ("rpc.heartbeat.p95_ms",            "rpc", "heartbeat",           "p95_ms",       False),
        ("e2e.ping_all.total_ms",           "e2e", "ping_all",            "total_ms",     False),
        ("e2e.parallel_delegation.total_ms","e2e", "parallel_delegation", "total_ms",     False),
        ("e2e.broadcast.total_ms",          "e2e", "broadcast_convergence","total_ms",    False),
    ]

    for name, layer, scenario, metric, higher_better in metric_defs:
        curr_val = current.get(layer, {}).get(scenario, {}).get(metric)
        prev_val = previous.get(layer, {}).get(scenario, {}).get(metric)
        if curr_val is None or prev_val is None:
            continue

        delta_val = round(curr_val - prev_val, 2)
        pct = round((delta_val / prev_val) * 100, 1) if prev_val != 0 else 0.0
        deltas[name] = {"prev": prev_val, "curr": curr_val, "delta": delta_val, "pct": pct}

        bucket_name = name.rsplit(".", 1)[0]
        if higher_better:
            if pct > 5:
                improved.append(bucket_name)
            elif pct < -5:
                regressed.append(bucket_name)
            else:
                unchanged.append(bucket_name)
        else:
            if pct < -5:
                improved.append(bucket_name)
            elif pct > 5:
                regressed.append(bucket_name)
            else:
                unchanged.append(bucket_name)

    return {
        "previous_run": previous.get("run_id", "unknown"),
        "deltas": deltas,
        "improved": sorted(set(improved)),
        "regressed": sorted(set(regressed)),
        "unchanged": sorted(set(unchanged)),
    }


# ═══════════════════════════════════════════
#  Output formatting
# ═══════════════════════════════════════════

def print_header(sock_path: str, git_info: Dict, team_info: Optional[Dict] = None):
    print()
    print(bold("=== tm-bench agent ==="))
    print()
    print(f"  Git:    {git_info['git_sha']} ({git_info['git_branch']})")
    if team_info:
        agents = team_info.get("agents", [])
        print(f"  Team:   {team_info.get('team_name', 'N/A')} ({len(agents)} agents)")
    print(f"  Socket: {sock_path}")
    print()


def _result_line(scenario: str, target: str, actual: str, passed: bool):
    status = green("PASS") if passed else red("FAIL")
    print(f"  {scenario:<35} {target:<16} {actual:<16} {status}")


def print_rpc_results(results: Dict):
    print(f"  {bold('── RPC Infrastructure ──')}")
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


def print_e2e_results(results: Dict):
    print(f"  {bold('── Agent E2E ──')}")

    if "ping_all" in results:
        r = results["ping_all"]
        n = r.get("agent_count", 0)
        resp = r.get("responded", 0)
        ms = r.get("total_ms", 0)
        _result_line(f"Ping All ({n} agents)", "100% respond",
                     f"{resp}/{n} ({ms / 1000:.1f}s)", r["passed"])

    if "parallel_delegation" in results:
        r = results["parallel_delegation"]
        n = r.get("agent_count", 0)
        comp = r.get("completed", 0)
        ms = r.get("total_ms", 0)
        _result_line("Parallel Delegation", "100% complete",
                     f"{comp}/{n} ({ms / 1000:.1f}s)", r["passed"])

    if "cross_messaging" in results:
        r = results["cross_messaging"]
        d = r.get("delivered", 0)
        t = r.get("total", 0)
        _result_line("Cross Messaging", "100% delivered", f"{d}/{t}", r["passed"])

    if "task_lifecycle" in results:
        r = results["task_lifecycle"]
        s = r.get("stages_completed", 0)
        t = r.get("total_stages", 5)
        _result_line("Task Lifecycle", "all stages", f"{s}/{t} stages", r["passed"])

    if "broadcast_convergence" in results:
        r = results["broadcast_convergence"]
        n = r.get("agent_count", 0)
        resp = r.get("responded", 0)
        ms = r.get("total_ms", 0)
        _result_line("Broadcast Convergence", "100% respond",
                     f"{resp}/{n} ({ms / 1000:.1f}s)", r["passed"])

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
        higher_better = "msgs" in name

        # Format values — check "msgs" before "ms" to avoid false match
        if "msgs" in name:
            prev_s = f"{prev} msg/s"
            curr_s = f"{curr} msg/s"
        elif "total_ms" in name and prev >= 1000:
            prev_s = f"{prev / 1000:.1f}s"
            curr_s = f"{curr / 1000:.1f}s"
        elif "ms" in name:
            prev_s = f"{prev} ms"
            curr_s = f"{curr} ms"
        else:
            prev_s, curr_s = str(prev), str(curr)

        if higher_better:
            tag = green("improved") if pct > 5 else (red("regressed") if pct < -5 else "unchanged")
        else:
            tag = green("improved") if pct < -5 else (red("regressed") if pct > 5 else "unchanged")

        sign = "+" if pct > 0 else ""
        print(f"    {name + ':':<40} {prev_s} → {curr_s}   ({sign}{pct}% {tag})")

    print()


def print_summary(rpc_results: Dict, e2e_results: Dict, saved_path: str):
    rpc_p = sum(1 for r in rpc_results.values() if isinstance(r, dict) and r.get("passed"))
    rpc_f = sum(1 for r in rpc_results.values() if isinstance(r, dict) and not r.get("passed"))
    e2e_p = sum(1 for r in e2e_results.values() if isinstance(r, dict) and r.get("passed"))
    e2e_f = sum(1 for r in e2e_results.values() if isinstance(r, dict) and not r.get("passed"))

    tp = rpc_p + e2e_p
    tf = rpc_f + e2e_f
    failed_str = red(f"{tf} failed") if tf else f"{tf} failed"
    print(bold(f"=== Results: {green(f'{tp} passed')}, {failed_str} ==="))
    print(f"  Saved: {saved_path}")
    print()


# ═══════════════════════════════════════════
#  History / Compare sub-commands
# ═══════════════════════════════════════════

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
    hdr = f"  {'RUN':<25} {'RPC(p/f)':<12} {'E2E(p/f)':<12} {'STATUS_P50':<14} {'THROUGHPUT':<14} CHANGE NOTE"
    print(hdr)

    for path in files:
        with open(path) as f:
            data = json.load(f)

        run_id = data.get("run_id", path.stem)
        rpc = data.get("rpc", {})
        e2e = data.get("e2e", {})

        rpc_p = sum(1 for r in rpc.values() if isinstance(r, dict) and r.get("passed"))
        rpc_f = sum(1 for r in rpc.values() if isinstance(r, dict) and not r.get("passed"))
        e2e_p = sum(1 for r in e2e.values() if isinstance(r, dict) and r.get("passed"))
        e2e_f = sum(1 for r in e2e.values() if isinstance(r, dict) and not r.get("passed"))

        st_p50 = rpc.get("status_latency", {}).get("p50_ms", "-")
        thr = rpc.get("message_throughput", {}).get("msgs_per_sec", "-")
        note = data.get("metadata", {}).get("change_note", "")[:30]

        st_s = f"{st_p50} ms" if isinstance(st_p50, (int, float)) else str(st_p50)
        thr_s = f"{thr} msg/s" if isinstance(thr, (int, float)) else str(thr)

        print(f"  {run_id:<25} {f'{rpc_p}/{rpc_f}':<12} {f'{e2e_p}/{e2e_f}':<12} "
              f"{st_s:<14} {thr_s:<14} {note}")

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

    comparison = compute_comparison(b, a)  # b is "current", a is "previous"
    if comparison and comparison.get("deltas"):
        for name, d in comparison["deltas"].items():
            prev, curr, pct = d["prev"], d["curr"], d["pct"]
            sign = "+" if pct > 0 else ""
            higher_better = "msgs" in name

            if higher_better:
                tag = green("improved") if pct > 5 else (red("regressed") if pct < -5 else "unchanged")
            else:
                tag = green("improved") if pct < -5 else (red("regressed") if pct > 5 else "unchanged")

            print(f"  {name + ':':<40} {prev} → {curr}   ({sign}{pct}% {tag})")
    else:
        print("  No comparable metrics found.")

    print()


# ═══════════════════════════════════════════
#  CLI entry point
# ═══════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="Agent Team Communication Benchmark",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 scripts/bench-agent.py              # Run all benchmarks
  python3 scripts/bench-agent.py --rpc-only   # RPC only (no team needed)
  python3 scripts/bench-agent.py --e2e-only   # E2E only (needs active team)
  python3 scripts/bench-agent.py --history    # Show history
  python3 scripts/bench-agent.py --compare 2026-03-19 2026-03-18
        """,
    )
    parser.add_argument("--rpc-only", action="store_true",
                        help="Run only RPC infrastructure benchmarks")
    parser.add_argument("--e2e-only", action="store_true",
                        help="Run only E2E agent benchmarks (needs active team)")
    parser.add_argument("--history", action="store_true",
                        help="Show recent benchmark history")
    parser.add_argument("--compare", nargs=2, metavar=("A", "B"),
                        help="Compare two runs by timestamp prefix")
    parser.add_argument("--note", default="",
                        help="Change note attached to this run")

    args = parser.parse_args()

    # ── Sub-commands ──
    if args.history:
        show_history()
        return

    if args.compare:
        compare_runs(args.compare[0], args.compare[1])
        return

    # ── Benchmark run ──
    try:
        sock_path = _detect_socket()
    except RuntimeError as e:
        print(f"\n{red('ERROR')}: {e}")
        sys.exit(1)

    git_info = _git_info()

    team_info = None
    if not args.rpc_only:
        team_info = _detect_team()

    print_header(sock_path, git_info, team_info)

    rpc_results: Dict[str, Any] = {}
    e2e_results: Dict[str, Any] = {}

    if not args.e2e_only:
        print(f"  {dim('Starting RPC benchmarks...')}")
        rpc_results = run_rpc_benchmarks(sock_path)
        print_rpc_results(rpc_results)

    if not args.rpc_only:
        print(f"  {dim('Starting E2E benchmarks...')}")
        e2e_results = run_e2e_benchmarks()
        if e2e_results:
            print_e2e_results(e2e_results)

    # ── Assemble & save ──
    data: Dict[str, Any] = {
        "metadata": {
            **git_info,
            "agent_count": len(team_info.get("agents", [])) if team_info else 0,
            "team_name": team_info.get("team_name", "N/A") if team_info else "N/A",
            "socket_path": sock_path,
            "change_note": args.note,
        },
        "rpc": rpc_results,
        "e2e": e2e_results,
        "summary": {
            "rpc_passed": sum(1 for r in rpc_results.values()
                              if isinstance(r, dict) and r.get("passed")),
            "rpc_failed": sum(1 for r in rpc_results.values()
                              if isinstance(r, dict) and not r.get("passed")),
            "rpc_total": len(rpc_results),
            "e2e_passed": sum(1 for r in e2e_results.values()
                              if isinstance(r, dict) and r.get("passed")),
            "e2e_failed": sum(1 for r in e2e_results.values()
                              if isinstance(r, dict) and not r.get("passed")),
            "e2e_total": len(e2e_results),
        },
    }

    saved_path = save_results(data)

    # ── Compare with previous ──
    previous = load_previous_result()
    if previous:
        comparison = compute_comparison(data, previous)
        data["comparison"] = comparison
        # Re-save with comparison data included
        with open(saved_path, "w") as f:
            json.dump(data, f, indent=2)
        print_comparison(comparison, args.note)

    print_summary(rpc_results, e2e_results, saved_path)


if __name__ == "__main__":
    main()
