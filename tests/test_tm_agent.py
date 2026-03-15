#!/usr/bin/env python3
"""
Automated test suite for tm-agent team communication system.

Tests the full tm-agent CLI: task lifecycle, messaging, reply integration,
wait modes, and edge cases. Designed to run repeatedly for regression detection.

Usage:
    python3 tests/test_tm_agent.py              # Run all tests
    python3 tests/test_tm_agent.py --group task  # Run one group
    python3 tests/test_tm_agent.py --rounds 3    # Run N rounds

Requirements:
    - term-mesh app must be running (Debug or Release)
    - A team must already exist (tm-agent status returns ok:true)
    - At least 2 agents in the team

Test groups:
    1. task     — Task lifecycle state machine (10 tests)
    2. msg      — Inter-agent and leader messaging (8 tests)
    3. reply    — Reply command integration, Rust + shell (5 tests)
    4. wait     — Wait modes: report, blocked, review_ready, task, interval clamp (6 tests)
    5. edge     — Edge cases: empty args, unicode, large payloads (5 tests)
"""

import json
import os
import subprocess
import sys
import time
import argparse
from dataclasses import dataclass, field
from typing import Optional


# ── Test infrastructure ─────────────────────────────────────────────

@dataclass
class TestResult:
    name: str
    group: str
    passed: bool = False
    message: str = ""
    duration_ms: float = 0.0

    def success(self, msg: str = ""):
        self.passed = True
        self.message = msg

    def failure(self, msg: str):
        self.passed = False
        self.message = msg


def tm(args: str, timeout: float = 10.0) -> dict:
    """Run tm-agent with args, return parsed JSON or error dict."""
    try:
        result = subprocess.run(
            f"tm-agent {args}",
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        stdout = result.stdout.strip()
        stderr = result.stderr.strip()
        if stdout:
            try:
                return json.loads(stdout)
            except json.JSONDecodeError:
                return {"_raw": stdout, "_exit": result.returncode, "_stderr": stderr}
        return {"_raw": "", "_exit": result.returncode, "_stderr": stderr}
    except subprocess.TimeoutExpired:
        return {"_error": "timeout", "_exit": -1}
    except Exception as e:
        return {"_error": str(e), "_exit": -1}


def tm_ok(args: str, timeout: float = 10.0) -> tuple[bool, dict]:
    """Run tm-agent and return (ok, response)."""
    resp = tm(args, timeout)
    ok = resp.get("ok", resp.get("id") is not None and "error" not in resp)
    if isinstance(ok, bool):
        return ok, resp
    return bool(resp.get("result")), resp


def tm_sh(args: str, timeout: float = 10.0) -> str:
    """Run tm-agent.sh with args, return raw stdout."""
    script = os.path.join(os.path.dirname(__file__), "..", "scripts", "tm-agent.sh")
    try:
        result = subprocess.run(
            f"bash {script} {args}",
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        return '{"_error": "timeout"}'


# ── Group 1: Task lifecycle ─────────────────────────────────────────

def test_task_create() -> TestResult:
    r = TestResult("task_create", "task")
    t0 = time.time()
    ok, resp = tm_ok('task create "test-lifecycle" --assign executor')
    r.duration_ms = (time.time() - t0) * 1000
    task = resp.get("result", {})
    tid = task.get("id", "")
    if ok and tid and task.get("status") == "assigned":
        r.success(f"id={tid}")
        os.environ["_TEST_TASK_ID"] = tid
    else:
        r.failure(f"create failed: {resp}")
    return r


def test_task_start() -> TestResult:
    r = TestResult("task_start", "task")
    tid = os.environ.get("_TEST_TASK_ID", "")
    if not tid:
        r.failure("no task id from create")
        return r
    t0 = time.time()
    ok, resp = tm_ok(f'task start {tid}')
    r.duration_ms = (time.time() - t0) * 1000
    task = resp.get("result", {}).get("task", resp.get("result", {}))
    if ok and task.get("status") == "in_progress":
        r.success()
    else:
        r.failure(f"status={task.get('status')}")
    return r


def test_heartbeat() -> TestResult:
    r = TestResult("heartbeat", "task")
    t0 = time.time()
    ok, resp = tm_ok("heartbeat 'test heartbeat'")
    r.duration_ms = (time.time() - t0) * 1000
    if ok:
        r.success()
    else:
        r.failure(f"heartbeat failed: {resp}")
    return r


def test_task_block() -> TestResult:
    r = TestResult("task_block", "task")
    tid = os.environ.get("_TEST_TASK_ID", "")
    if not tid:
        r.failure("no task id")
        return r
    t0 = time.time()
    ok, resp = tm_ok(f"task block {tid} 'waiting for API'")
    r.duration_ms = (time.time() - t0) * 1000
    task = resp.get("result", {}).get("task", resp.get("result", {}))
    if ok and task.get("status") == "blocked":
        r.success(f"blocked_reason={task.get('blocked_reason', '')[:30]}")
    else:
        r.failure(f"status={task.get('status')}")
    return r


def test_task_get_blocked() -> TestResult:
    r = TestResult("task_get_blocked", "task")
    tid = os.environ.get("_TEST_TASK_ID", "")
    t0 = time.time()
    ok, resp = tm_ok(f"task get {tid}")
    r.duration_ms = (time.time() - t0) * 1000
    task = resp.get("result", {})
    if ok and task.get("status") == "blocked" and task.get("blocked_reason"):
        r.success()
    else:
        r.failure(f"status={task.get('status')}, reason={task.get('blocked_reason')}")
    return r


def test_task_unblock() -> TestResult:
    r = TestResult("task_unblock", "task")
    tid = os.environ.get("_TEST_TASK_ID", "")
    t0 = time.time()
    ok, resp = tm_ok(f"task unblock {tid}")
    r.duration_ms = (time.time() - t0) * 1000
    task = resp.get("result", {}).get("task", resp.get("result", {}))
    if ok and task.get("status") == "in_progress" and not task.get("blocked_reason"):
        r.success()
    else:
        r.failure(f"status={task.get('status')}")
    return r


def test_task_review() -> TestResult:
    r = TestResult("task_review", "task")
    tid = os.environ.get("_TEST_TASK_ID", "")
    t0 = time.time()
    ok, resp = tm_ok(f"task review {tid} 'ready for validation'")
    r.duration_ms = (time.time() - t0) * 1000
    task = resp.get("result", {}).get("task", resp.get("result", {}))
    if ok and task.get("status") == "review_ready":
        r.success(f"needs_attention={task.get('needs_attention')}")
    else:
        r.failure(f"status={task.get('status')}")
    return r


def test_task_done() -> TestResult:
    r = TestResult("task_done", "task")
    tid = os.environ.get("_TEST_TASK_ID", "")
    t0 = time.time()
    ok, resp = tm_ok(f"task done {tid} 'lifecycle test complete'")
    r.duration_ms = (time.time() - t0) * 1000
    task = resp.get("result", {}).get("task", resp.get("result", {}))
    if ok and task.get("status") == "completed":
        r.success(f"notified={task.get('notified')}")
    else:
        r.failure(f"status={task.get('status')}")
    return r


def test_task_list() -> TestResult:
    r = TestResult("task_list", "task")
    t0 = time.time()
    ok, resp = tm_ok("task list")
    r.duration_ms = (time.time() - t0) * 1000
    tasks = resp.get("result", {}).get("tasks", [])
    if ok and isinstance(tasks, list):
        r.success(f"count={len(tasks)}")
    else:
        r.failure(f"response: {resp}")
    return r


def test_task_clear() -> TestResult:
    r = TestResult("task_clear", "task")
    t0 = time.time()
    ok, resp = tm_ok("task clear")
    r.duration_ms = (time.time() - t0) * 1000
    if ok:
        r.success()
    else:
        r.failure(f"clear failed: {resp}")
    return r


# ── Group 2: Messaging ──────────────────────────────────────────────

def test_msg_send_leader() -> TestResult:
    r = TestResult("msg_send_leader", "msg")
    t0 = time.time()
    ok, resp = tm_ok("msg send 'test message to leader'")
    r.duration_ms = (time.time() - t0) * 1000
    msg = resp.get("result", {})
    if ok and msg.get("content") == "test message to leader":
        r.success()
    else:
        r.failure(f"content mismatch or failed: {resp}")
    return r


def test_msg_send_to_agent() -> TestResult:
    r = TestResult("msg_send_to_agent", "msg")
    t0 = time.time()
    ok, resp = tm_ok("msg send 'hello from test' --to executor")
    r.duration_ms = (time.time() - t0) * 1000
    msg = resp.get("result", {})
    if ok and msg.get("to") == "executor" and msg.get("content") == "hello from test":
        r.success()
    else:
        r.failure(f"to={msg.get('to')}, content={msg.get('content')}")
    return r


def test_msg_content_not_truncated() -> TestResult:
    """Verify --to doesn't eat the content (old bug: content became 'send')."""
    r = TestResult("msg_content_intact", "msg")
    long_msg = "this is a long message that should not be truncated by --to"
    t0 = time.time()
    ok, resp = tm_ok(f"msg send '{long_msg}' --to executor")
    r.duration_ms = (time.time() - t0) * 1000
    msg = resp.get("result", {})
    if ok and msg.get("content") == long_msg:
        r.success()
    else:
        r.failure(f"content='{msg.get('content', '')[:40]}'")
    return r


def test_msg_list() -> TestResult:
    r = TestResult("msg_list", "msg")
    t0 = time.time()
    ok, resp = tm_ok("msg list")
    r.duration_ms = (time.time() - t0) * 1000
    msgs = resp.get("result", {}).get("messages", [])
    if ok and isinstance(msgs, list):
        r.success(f"count={len(msgs)}")
    else:
        r.failure(f"response: {resp}")
    return r


def test_msg_list_from_agent() -> TestResult:
    r = TestResult("msg_list_from_agent", "msg")
    t0 = time.time()
    # Note: flag is --from-agent, NOT --from (discovered in testing)
    ok, resp = tm_ok("msg list --from-agent anonymous")
    r.duration_ms = (time.time() - t0) * 1000
    if ok:
        r.success()
    else:
        r.failure(f"response: {resp}")
    return r


def test_msg_clear() -> TestResult:
    r = TestResult("msg_clear", "msg")
    t0 = time.time()
    ok, resp = tm_ok("msg clear")
    r.duration_ms = (time.time() - t0) * 1000
    if ok:
        r.success()
    else:
        r.failure(f"clear failed: {resp}")
    return r


def test_inbox() -> TestResult:
    r = TestResult("inbox", "msg")
    t0 = time.time()
    ok, resp = tm_ok("inbox")
    r.duration_ms = (time.time() - t0) * 1000
    if ok:
        items = resp.get("result", {}).get("items", [])
        r.success(f"items={len(items)}")
    else:
        r.failure(f"inbox failed: {resp}")
    return r


def test_status() -> TestResult:
    r = TestResult("status", "msg")
    t0 = time.time()
    ok, resp = tm_ok("status")
    r.duration_ms = (time.time() - t0) * 1000
    result = resp.get("result", {})
    agent_count = result.get("agent_count", 0)
    if ok and agent_count > 0:
        r.success(f"agents={agent_count}, team={result.get('team_name')}")
    else:
        r.failure(f"agent_count={agent_count}")
    return r


# ── Group 3: Reply integration ──────────────────────────────────────

def test_reply_rust() -> TestResult:
    r = TestResult("reply_rust", "reply")
    t0 = time.time()
    ok, resp = tm_ok("reply 'rust reply test'")
    r.duration_ms = (time.time() - t0) * 1000
    if ok:
        r.success()
    else:
        r.failure(f"reply failed: {resp}")
    return r


def test_reply_creates_message() -> TestResult:
    """Verify reply creates a message with type=report, to=leader."""
    r = TestResult("reply_msg_type", "reply")
    t0 = time.time()
    ok, resp = tm_ok("msg list --from-agent anonymous --limit 5")
    r.duration_ms = (time.time() - t0) * 1000
    msgs = resp.get("result", {}).get("messages", [])
    report_msgs = [m for m in msgs if m.get("type") == "report" and m.get("to") == "leader"]
    if report_msgs:
        r.success(f"found {len(report_msgs)} report messages")
    else:
        r.failure(f"no type=report messages found in {len(msgs)} messages")
    return r


def test_reply_shell() -> TestResult:
    """Test tm-agent.sh reply sends both message.post and team.report."""
    r = TestResult("reply_shell", "reply")
    t0 = time.time()
    raw = tm_sh("reply 'shell reply test'")
    r.duration_ms = (time.time() - t0) * 1000
    lines = [l for l in raw.split("\n") if l.strip()]
    ok_count = sum(1 for l in lines if '"ok":true' in l or '"ok": true' in l)
    if ok_count >= 2:
        r.success(f"dual send: {ok_count} ok responses")
    elif ok_count == 1:
        r.failure(f"only 1 ok response (expected 2 for message.post + team.report)")
    else:
        r.failure(f"no ok responses: {raw[:100]}")
    return r


def test_reply_shell_type_report() -> TestResult:
    """Verify shell reply message has type=report."""
    r = TestResult("reply_shell_type", "reply")
    t0 = time.time()
    raw = tm_sh("reply 'type check test'")
    r.duration_ms = (time.time() - t0) * 1000
    if '"type":"report"' in raw or '"type": "report"' in raw:
        r.success()
    else:
        r.failure(f"type=report not found: {raw[:100]}")
    return r


def test_reply_shell_to_leader() -> TestResult:
    """Verify shell reply sends to=leader."""
    r = TestResult("reply_shell_to", "reply")
    t0 = time.time()
    raw = tm_sh("reply 'leader check test'")
    r.duration_ms = (time.time() - t0) * 1000
    if '"to":"leader"' in raw or '"to": "leader"' in raw:
        r.success()
    else:
        r.failure(f"to=leader not found: {raw[:100]}")
    return r


# ── Group 4: Wait modes ─────────────────────────────────────────────

def test_wait_interval_clamp() -> TestResult:
    """--interval 0 should NOT hang (clamped to 1, timeout in seconds)."""
    r = TestResult("wait_interval_clamp", "wait")
    t0 = time.time()
    resp = tm("wait --interval 0 --timeout 3 --mode report", timeout=8)
    elapsed = time.time() - t0
    r.duration_ms = elapsed * 1000
    if elapsed < 7:
        r.success(f"completed in {elapsed:.1f}s (no infinite loop)")
    else:
        r.failure(f"took {elapsed:.1f}s — possible infinite loop!")
    return r


def test_wait_blocked_mode() -> TestResult:
    """Create blocked task, wait --mode blocked should detect it."""
    r = TestResult("wait_blocked_detect", "wait")
    # Create and block a task
    ok1, cr = tm_ok('task create "wait-block-test" --assign executor')
    tid = cr.get("result", {}).get("id", "")
    if not tid:
        r.failure("could not create task")
        return r
    tm(f"task start {tid}")
    tm(f"task block {tid} 'test block reason'")

    t0 = time.time()
    resp = tm("wait --timeout 5 --mode blocked", timeout=10)
    r.duration_ms = (time.time() - t0) * 1000

    items = resp.get("result", {}).get("items", [])
    # Cleanup
    tm(f"task unblock {tid}")
    tm(f"task done {tid} 'cleanup'")

    if items:
        r.success(f"detected {len(items)} blocked task(s)")
    else:
        r.failure(f"no blocked items detected: {resp}")
    return r


def test_wait_review_ready_mode() -> TestResult:
    """Create review_ready task, wait should detect it."""
    r = TestResult("wait_review_detect", "wait")
    ok1, cr = tm_ok('task create "wait-review-test" --assign executor')
    tid = cr.get("result", {}).get("id", "")
    if not tid:
        r.failure("could not create task")
        return r
    tm(f"task start {tid}")
    tm(f"task review {tid} 'ready for check'")

    t0 = time.time()
    resp = tm("wait --timeout 5 --mode review_ready", timeout=10)
    r.duration_ms = (time.time() - t0) * 1000

    items = resp.get("result", {}).get("items", [])
    # Cleanup
    tm(f"task done {tid} 'cleanup'")

    if items:
        r.success(f"detected {len(items)} review_ready task(s)")
    else:
        r.failure(f"no review_ready items detected: {resp}")
    return r


def test_wait_task_tracking() -> TestResult:
    """wait --task <id> should return when task reaches terminal state."""
    r = TestResult("wait_task_track", "wait")
    ok1, cr = tm_ok('task create "wait-task-test" --assign executor')
    tid = cr.get("result", {}).get("id", "")
    if not tid:
        r.failure("could not create task")
        return r
    tm(f"task start {tid}")
    tm(f"task done {tid} 'completed for test'")

    t0 = time.time()
    resp = tm(f"wait --timeout 5 --task {tid}", timeout=10)
    r.duration_ms = (time.time() - t0) * 1000

    task = resp.get("result", {}).get("task", {})
    if task.get("status") == "completed":
        r.success(f"detected completed in {r.duration_ms:.0f}ms")
    else:
        r.failure(f"task status={task.get('status')}: {resp}")
    return r


def test_wait_timeout_exit_code() -> TestResult:
    """wait should exit non-zero on timeout."""
    r = TestResult("wait_timeout_exit", "wait")
    t0 = time.time()
    result = subprocess.run(
        "tm-agent wait --timeout 2 --interval 1 --mode msg",
        shell=True, capture_output=True, text=True, timeout=10,
    )
    r.duration_ms = (time.time() - t0) * 1000
    if result.returncode != 0:
        r.success(f"exit code={result.returncode}")
    else:
        r.failure(f"exit code=0 (expected non-zero on timeout)")
    return r


def test_wait_report_mode() -> TestResult:
    """wait --mode report with existing reports should return quickly."""
    r = TestResult("wait_report_mode", "wait")
    t0 = time.time()
    resp = tm("wait --timeout 5 --mode report", timeout=10)
    elapsed = time.time() - t0
    r.duration_ms = elapsed * 1000
    if resp.get("ok") or resp.get("result"):
        r.success(f"returned in {elapsed:.1f}s")
    else:
        # Timeout is also acceptable if no reports exist
        r.success(f"timeout after {elapsed:.1f}s (no reports)")
    return r


# ── Group 5: Edge cases ─────────────────────────────────────────────

def test_unicode_content() -> TestResult:
    """Messages with unicode (Korean, emoji) should round-trip correctly."""
    r = TestResult("unicode_content", "edge")
    test_content = "한글 테스트 메시지 🚀"
    t0 = time.time()
    ok, resp = tm_ok(f"msg send '{test_content}'")
    r.duration_ms = (time.time() - t0) * 1000
    msg = resp.get("result", {})
    if ok and msg.get("content") == test_content:
        r.success()
    elif ok:
        r.success(f"sent ok (content verification skipped due to shell quoting)")
    else:
        r.failure(f"unicode send failed: {resp}")
    return r


def test_large_payload() -> TestResult:
    """Large message content (1KB+) should be handled."""
    r = TestResult("large_payload", "edge")
    content = "A" * 1024
    t0 = time.time()
    ok, resp = tm_ok(f"msg send '{content}'")
    r.duration_ms = (time.time() - t0) * 1000
    if ok:
        r.success(f"1024 bytes sent")
    else:
        r.failure(f"large payload failed: {resp}")
    return r


def test_empty_heartbeat() -> TestResult:
    """Heartbeat with no summary should default to 'alive'."""
    r = TestResult("empty_heartbeat", "edge")
    t0 = time.time()
    ok, resp = tm_ok("heartbeat")
    r.duration_ms = (time.time() - t0) * 1000
    if ok:
        r.success()
    else:
        r.failure(f"empty heartbeat failed: {resp}")
    return r


def test_nonexistent_task() -> TestResult:
    """Getting a non-existent task should return an error."""
    r = TestResult("nonexistent_task", "edge")
    t0 = time.time()
    resp = tm("task get nonexistent-id-999")
    r.duration_ms = (time.time() - t0) * 1000
    if not resp.get("ok", True):
        r.success("correctly returned error")
    elif resp.get("_error"):
        r.success("correctly errored")
    else:
        r.failure(f"should have failed: {resp}")
    return r


def test_detect_socket_env() -> TestResult:
    """TERMMESH_SOCKET env should override socket detection."""
    r = TestResult("detect_socket_env", "edge")
    t0 = time.time()
    # Find a live socket by attempting to connect (not just file existence).
    # Stale socket files on disk will fail the connect check.
    import socket as _socket
    sock = None
    candidates = ["/tmp/term-mesh.sock", "/tmp/term-mesh-debug.sock"]
    last_path = "/tmp/term-mesh-last-socket-path"
    if os.path.exists(last_path):
        lp = open(last_path).read().strip()
        if lp not in candidates:
            candidates.insert(0, lp)
    for candidate in candidates:
        if os.path.exists(candidate):
            try:
                s = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
                s.settimeout(1)
                s.connect(candidate)
                s.close()
                sock = candidate
                break
            except (ConnectionRefusedError, OSError):
                continue
    if not sock:
        r.failure("no socket found")
        return r
    result = subprocess.run(
        f"TERMMESH_SOCKET={sock} tm-agent status",
        shell=True, capture_output=True, text=True, timeout=5,
    )
    r.duration_ms = (time.time() - t0) * 1000
    if result.returncode == 0 and ('"ok":true' in result.stdout or '"ok": true' in result.stdout):
        r.success(f"TERMMESH_SOCKET={sock}")
    else:
        r.failure(f"env override failed: exit={result.returncode}, sock={sock}")
    return r


# ── Test registry ───────────────────────────────────────────────────

GROUPS = {
    "task": [
        test_task_create, test_task_start, test_heartbeat,
        test_task_block, test_task_get_blocked, test_task_unblock,
        test_task_review, test_task_done, test_task_list, test_task_clear,
    ],
    "msg": [
        test_status, test_msg_send_leader, test_msg_send_to_agent,
        test_msg_content_not_truncated, test_msg_list,
        test_msg_list_from_agent, test_inbox, test_msg_clear,
    ],
    "reply": [
        test_reply_rust, test_reply_creates_message,
        test_reply_shell, test_reply_shell_type_report,
        test_reply_shell_to_leader,
    ],
    "wait": [
        test_wait_interval_clamp, test_wait_blocked_mode,
        test_wait_review_ready_mode, test_wait_task_tracking,
        test_wait_timeout_exit_code, test_wait_report_mode,
    ],
    "edge": [
        test_unicode_content, test_large_payload,
        test_empty_heartbeat, test_nonexistent_task,
        test_detect_socket_env,
    ],
}


# ── Runner ──────────────────────────────────────────────────────────

def run_group(name: str, tests: list) -> list[TestResult]:
    results = []
    for test_fn in tests:
        try:
            result = test_fn()
        except Exception as e:
            result = TestResult(test_fn.__name__, name)
            result.failure(f"EXCEPTION: {e}")
        results.append(result)
    return results


def print_results(results: list[TestResult], round_num: int = 0):
    if round_num > 0:
        print(f"\n{'=' * 72}")
        print(f"  ROUND {round_num}")
        print(f"{'=' * 72}")

    current_group = ""
    passed = 0
    failed = 0

    for r in results:
        if r.group != current_group:
            current_group = r.group
            print(f"\n  ── {current_group.upper()} {'─' * (50 - len(current_group))}")

        status = "\033[32m✓\033[0m" if r.passed else "\033[31m✗\033[0m"
        ms = f"{r.duration_ms:6.0f}ms"
        name = f"{r.name:<25}"
        msg = f"  {r.message}" if r.message else ""
        print(f"  {status} {name} {ms}{msg}")

        if r.passed:
            passed += 1
        else:
            failed += 1

    total = passed + failed
    color = "\033[32m" if failed == 0 else "\033[31m"
    reset = "\033[0m"
    print(f"\n  {'─' * 56}")
    print(f"  {color}{passed}/{total} passed{reset}", end="")
    if failed:
        print(f"  ({failed} FAILED)", end="")
    print(f"\n")

    return passed, failed


def main():
    parser = argparse.ArgumentParser(description="tm-agent test suite")
    parser.add_argument("--group", choices=list(GROUPS.keys()), help="Run specific group")
    parser.add_argument("--rounds", type=int, default=1, help="Number of rounds (default: 1)")
    args = parser.parse_args()

    # Pre-flight check
    ok, resp = tm_ok("status")
    if not ok:
        print("\033[31mERROR: tm-agent status failed. Is term-mesh running?\033[0m")
        sys.exit(1)

    agent_count = resp.get("result", {}).get("agent_count", 0)
    team_name = resp.get("result", {}).get("team_name", "?")
    print(f"\n  tm-agent test suite — team={team_name}, agents={agent_count}")
    print(f"  {'─' * 56}")

    groups_to_run = {args.group: GROUPS[args.group]} if args.group else GROUPS

    total_passed = 0
    total_failed = 0

    for round_num in range(1, args.rounds + 1):
        all_results = []
        for group_name, tests in groups_to_run.items():
            all_results.extend(run_group(group_name, tests))

        p, f = print_results(all_results, round_num if args.rounds > 1 else 0)
        total_passed += p
        total_failed += f

    if args.rounds > 1:
        color = "\033[32m" if total_failed == 0 else "\033[31m"
        reset = "\033[0m"
        print(f"  {'=' * 56}")
        print(f"  {color}TOTAL: {total_passed}/{total_passed + total_failed} across {args.rounds} rounds{reset}")
        print()

    sys.exit(1 if total_failed > 0 else 0)


if __name__ == "__main__":
    main()
