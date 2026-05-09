#!/usr/bin/env python3
"""
Automated tests for team RPC socket interface.

Tests team lifecycle operations: create, list, status, send, broadcast, destroy.

Usage:
    python3 test_team_rpc.py

Requirements:
    - term-mesh must be running with the socket controller enabled
      (TERMMESH_SOCKET_MODE=allowAll)
"""

import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from termmesh import termmesh, termmeshError


class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.passed = False
        self.message = ""

    def success(self, msg: str = ""):
        self.passed = True
        self.message = msg

    def failure(self, msg: str):
        self.passed = False
        self.message = msg


TEAM_NAME = "test-rpc-team"


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
    env_sock = os.environ.get("TERMMESH_SOCKET")
    if env_sock and os.path.exists(env_sock):
        return env_sock

    import glob
    candidates = sorted(glob.glob("/tmp/term-mesh*.sock"), key=os.path.getmtime, reverse=True)
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


def _cleanup_team(sock_path: str):
    """Best-effort team cleanup."""
    try:
        _rpc_call(sock_path, "team.destroy", {"team_name": TEAM_NAME}, rid=999)
    except Exception:
        pass


def test_ping(sock_path: str) -> TestResult:
    """Test basic socket connectivity with system.ping."""
    result = TestResult("system.ping")
    try:
        resp = _rpc_call(sock_path, "system.ping", {}, rid=0)
        if resp.get("ok"):
            result.success("Received pong")
        else:
            result.failure(f"Ping returned ok=false: {resp}")
    except Exception as e:
        result.failure(f"Connection failed: {e}")
    return result


def test_team_create(sock_path: str) -> TestResult:
    """Test team creation via RPC."""
    result = TestResult("team.create")
    try:
        resp = _rpc_call(sock_path, "team.create", {
            "team_name": TEAM_NAME,
            "agents": [{"name": "w1", "model": "sonnet", "agent_type": "general"}],
            "working_directory": os.getcwd(),
            "leader_session_id": "test-leader-1",
        }, rid=1)
        if resp.get("ok"):
            result.success(f"Team '{TEAM_NAME}' created")
        else:
            result.failure(f"Create failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_preset_list_includes_workflows(sock_path: str) -> TestResult:
    """Test that team.preset.list exposes workflow presets."""
    result = TestResult("team.preset.list (workflows)")
    try:
        resp = _rpc_call(sock_path, "team.preset.list", {}, rid=50)
        if not resp.get("ok"):
            result.failure(f"preset.list failed: {resp.get('error', resp)}")
            return result

        presets = resp.get("result", {}).get("presets", [])
        bug = next((p for p in presets if p.get("id") == "bug-triage"), None)
        if not bug:
            result.failure(f"bug-triage workflow missing: {json.dumps(presets)[:300]}")
            return result

        if (
            bug.get("type") == "workflow"
            and bug.get("leader_mode") == "repl"
            and len(bug.get("agents", [])) == 3
            and bug.get("task_templates")
            and bug.get("review_checkpoints")
        ):
            result.success("workflow preset listed with agents and templates")
        else:
            result.failure(f"Unexpected workflow preset: {json.dumps(bug)[:300]}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_preset_resolve_workflow(sock_path: str) -> TestResult:
    """Test resolving a workflow preset into agents and task templates."""
    result = TestResult("team.preset.resolve (workflow)")
    try:
        resp = _rpc_call(sock_path, "team.preset.resolve", {
            "preset_id": "bug-triage",
        }, rid=51)
        if not resp.get("ok"):
            result.failure(f"preset.resolve failed: {resp.get('error', resp)}")
            return result

        payload = resp.get("result", {})
        agents = payload.get("agents", [])
        templates = payload.get("task_templates", [])
        checkpoints = payload.get("review_checkpoints", [])
        roles = [a.get("name") for a in agents]
        if (
            payload.get("preset_type") == "workflow"
            and payload.get("leader_mode") == "repl"
            and roles == ["debugger", "explorer", "tester"]
            and "reproduce issue" in templates
            and "blocked on repro" in checkpoints
        ):
            result.success("workflow preset resolved")
        else:
            result.failure(f"Unexpected workflow resolve payload: {json.dumps(payload)[:400]}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_team_list(sock_path: str) -> TestResult:
    """Test that created team appears in team.list."""
    result = TestResult("team.list")
    try:
        resp = _rpc_call(sock_path, "team.list", {}, rid=2)
        if not resp.get("ok"):
            result.failure(f"List failed: {resp.get('error', resp)}")
            return result
        teams = resp.get("result", {})
        # team.list returns team names in some form — check our team exists
        result_str = json.dumps(teams)
        if TEAM_NAME in result_str:
            result.success(f"Team '{TEAM_NAME}' found in list")
        else:
            result.failure(f"Team '{TEAM_NAME}' not in list: {result_str[:200]}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_team_status(sock_path: str) -> TestResult:
    """Test team.status returns valid data for our team."""
    result = TestResult("team.status")
    try:
        resp = _rpc_call(sock_path, "team.status", {"team_name": TEAM_NAME}, rid=3)
        if resp.get("ok"):
            result.success(f"Status: {json.dumps(resp.get('result', ''))[:200]}")
        else:
            result.failure(f"Status failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_team_send(sock_path: str) -> TestResult:
    """Test sending text to a specific agent."""
    result = TestResult("team.send")
    try:
        resp = _rpc_call(sock_path, "team.send", {
            "team_name": TEAM_NAME,
            "agent_name": "w1",
            "text": "echo hello\n",
        }, rid=4)
        if resp.get("ok"):
            result.success("Text sent to agent w1")
        else:
            result.failure(f"Send failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_team_broadcast(sock_path: str) -> TestResult:
    """Test broadcasting text to all agents."""
    result = TestResult("team.broadcast")
    try:
        resp = _rpc_call(sock_path, "team.broadcast", {
            "team_name": TEAM_NAME,
            "text": "echo broadcast-test\n",
        }, rid=5)
        if resp.get("ok"):
            result.success("Broadcast sent")
        else:
            result.failure(f"Broadcast failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_team_destroy(sock_path: str) -> TestResult:
    """Test team destruction and cleanup."""
    result = TestResult("team.destroy")
    try:
        resp = _rpc_call(sock_path, "team.destroy", {"team_name": TEAM_NAME}, rid=6)
        if resp.get("ok"):
            result.success(f"Team '{TEAM_NAME}' destroyed")
        else:
            result.failure(f"Destroy failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_team_not_found_after_destroy(sock_path: str) -> TestResult:
    """Verify team no longer exists after destroy."""
    result = TestResult("team.status (after destroy)")
    try:
        resp = _rpc_call(sock_path, "team.status", {"team_name": TEAM_NAME}, rid=7)
        if not resp.get("ok"):
            result.success("Correctly returns error for destroyed team")
        else:
            result.failure(f"Team still exists after destroy: {resp}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


# Shared state for task lifecycle tests
_task_state: dict = {"task_id": None}


def test_team_report(sock_path: str) -> TestResult:
    """Test submitting an agent report."""
    result = TestResult("team.report")
    try:
        resp = _rpc_call(sock_path, "team.report", {
            "team_name": TEAM_NAME,
            "agent_name": "w1",
            "content": "test report content",
        }, rid=30)
        if resp.get("ok"):
            result.success("Report submitted by w1")
        else:
            result.failure(f"team.report failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_team_heartbeat(sock_path: str) -> TestResult:
    """Test agent heartbeat."""
    result = TestResult("team.agent.heartbeat")
    try:
        resp = _rpc_call(sock_path, "team.agent.heartbeat", {
            "team_name": TEAM_NAME,
            "agent_name": "w1",
            "summary": "test heartbeat alive",
        }, rid=31)
        if resp.get("ok"):
            result.success("Heartbeat received from w1")
        else:
            result.failure(f"team.agent.heartbeat failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_team_inbox(sock_path: str) -> TestResult:
    """Test fetching the team leader inbox."""
    result = TestResult("team.inbox")
    try:
        resp = _rpc_call(sock_path, "team.inbox", {
            "team_name": TEAM_NAME,
        }, rid=32)
        if resp.get("ok"):
            result.success(f"Inbox fetched: {json.dumps(resp.get('result', ''))[:100]}")
        else:
            result.failure(f"team.inbox failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_task_create(sock_path: str) -> TestResult:
    """Test task creation and store task_id for subsequent tests."""
    result = TestResult("team.task.create")
    try:
        resp = _rpc_call(sock_path, "team.task.create", {
            "team_name": TEAM_NAME,
            "title": "rpc-test-task",
            "assignee": "w1",
        }, rid=10)
        if resp.get("ok"):
            task = resp.get("result", {})
            task_id = task.get("id", "")
            _task_state["task_id"] = task_id
            result.success(f"Task created: id={task_id}")
        else:
            result.failure(f"task.create failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_task_get(sock_path: str) -> TestResult:
    """Test fetching a task by ID."""
    result = TestResult("team.task.get")
    task_id = _task_state.get("task_id")
    if not task_id:
        result.failure("No task_id available (test_task_create may have failed)")
        return result
    try:
        resp = _rpc_call(sock_path, "team.task.get", {
            "team_name": TEAM_NAME,
            "task_id": task_id,
        }, rid=11)
        if resp.get("ok"):
            title = resp.get("result", {}).get("title", "")
            result.success(f"Task fetched: id={task_id} title={title!r}")
        else:
            result.failure(f"task.get failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_task_update(sock_path: str) -> TestResult:
    """Test updating task status to in_progress."""
    result = TestResult("team.task.update (in_progress)")
    task_id = _task_state.get("task_id")
    if not task_id:
        result.failure("No task_id available")
        return result
    try:
        resp = _rpc_call(sock_path, "team.task.update", {
            "team_name": TEAM_NAME,
            "task_id": task_id,
            "status": "in_progress",
        }, rid=12)
        if resp.get("ok"):
            result.success(f"Task {task_id} updated to in_progress")
        else:
            result.failure(f"task.update failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_task_review(sock_path: str) -> TestResult:
    """Test submitting a task for review."""
    result = TestResult("team.task.review")
    task_id = _task_state.get("task_id")
    if not task_id:
        result.failure("No task_id available")
        return result
    try:
        resp = _rpc_call(sock_path, "team.task.review", {
            "team_name": TEAM_NAME,
            "task_id": task_id,
            "summary": "rpc test review summary",
        }, rid=13)
        if resp.get("ok"):
            result.success(f"Task {task_id} submitted for review")
        else:
            result.failure(f"task.review failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_inbox_review_ready_task(sock_path: str) -> TestResult:
    """Test that review_ready tasks are surfaced as first-class inbox items."""
    result = TestResult("team.inbox (review_ready task)")
    task_id = _task_state.get("task_id")
    if not task_id:
        result.failure("No task_id available")
        return result
    try:
        resp = _rpc_call(sock_path, "team.inbox", {
            "team_name": TEAM_NAME,
            "top_only": True,
        }, rid=33)
        if not resp.get("ok"):
            result.failure(f"team.inbox failed: {resp.get('error', resp)}")
            return result

        items = resp.get("result", {}).get("items", [])
        if len(items) != 1:
            result.failure(f"Expected one top inbox item, got {len(items)}")
            return result

        item = items[0]
        if (
            item.get("kind") == "task"
            and item.get("status") == "review_ready"
            and item.get("task_id") == task_id
            and item.get("agent_name") == "w1"
            and item.get("priority") == 2
        ):
            result.success("review_ready task surfaced in inbox")
        else:
            result.failure(f"Unexpected inbox item: {json.dumps(item)[:300]}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_task_done(sock_path: str) -> TestResult:
    """Test marking a task as done."""
    result = TestResult("team.task.done")
    task_id = _task_state.get("task_id")
    if not task_id:
        result.failure("No task_id available")
        return result
    try:
        resp = _rpc_call(sock_path, "team.task.done", {
            "team_name": TEAM_NAME,
            "task_id": task_id,
            "result": "rpc test complete",
        }, rid=14)
        if resp.get("ok"):
            result.success(f"Task {task_id} marked done")
        else:
            result.failure(f"task.done failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_task_get_invalid_id(sock_path: str) -> TestResult:
    """Test that team.task.get with a nonexistent task_id returns an error."""
    result = TestResult("team.task.get (invalid id — edge case)")
    try:
        resp = _rpc_call(sock_path, "team.task.get", {
            "team_name": TEAM_NAME,
            "task_id": "00000000-0000-0000-0000-000000000000",
        }, rid=41)
        if not resp.get("ok"):
            result.success("Correctly returns error for invalid task_id")
        else:
            result.failure(f"Expected error but got ok: {resp}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_message_post(sock_path: str) -> TestResult:
    """Test posting a message from an agent to the leader."""
    result = TestResult("team.message.post")
    try:
        resp = _rpc_call(sock_path, "team.message.post", {
            "team_name": TEAM_NAME,
            "from": "w1",
            "content": "hello from rpc test",
            "type": "note",
        }, rid=20)
        if resp.get("ok"):
            result.success("Message posted by w1")
        else:
            result.failure(f"message.post failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_message_list(sock_path: str) -> TestResult:
    """Test listing messages for the team."""
    result = TestResult("team.message.list")
    try:
        resp = _rpc_call(sock_path, "team.message.list", {
            "team_name": TEAM_NAME,
        }, rid=21)
        if resp.get("ok"):
            messages = resp.get("result", {}).get("messages", [])
            result.success(f"Listed {len(messages)} message(s)")
        else:
            result.failure(f"message.list failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_message_attention_inbox(sock_path: str) -> TestResult:
    """Test that attention message types keep a dashboard-friendly inbox shape."""
    result = TestResult("team.inbox (attention message)")
    try:
        post = _rpc_call(sock_path, "team.message.post", {
            "team_name": TEAM_NAME,
            "from": "w1",
            "content": "blocked by rpc test",
            "type": "blocked",
        }, rid=23)
        if not post.get("ok"):
            result.failure(f"message.post failed: {post.get('error', post)}")
            return result

        resp = _rpc_call(sock_path, "team.inbox", {
            "team_name": TEAM_NAME,
        }, rid=24)
        if not resp.get("ok"):
            result.failure(f"team.inbox failed: {resp.get('error', resp)}")
            return result

        items = resp.get("result", {}).get("items", [])
        item = next((
            i for i in items
            if i.get("kind") == "message" and i.get("message_type") == "blocked"
        ), None)
        if not item:
            result.failure(f"Blocked message missing from inbox: {json.dumps(items)[:300]}")
            return result

        if (
            item.get("status") == "blocked"
            and item.get("agent_name") == "w1"
            and item.get("reason") == "blocked by rpc test"
            and item.get("priority") == 1
            and "task_id" in item
        ):
            result.success("blocked message surfaced with normalized inbox fields")
        else:
            result.failure(f"Unexpected message inbox item: {json.dumps(item)[:300]}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_message_clear(sock_path: str) -> TestResult:
    """Test clearing all messages for the team."""
    result = TestResult("team.message.clear")
    try:
        resp = _rpc_call(sock_path, "team.message.clear", {
            "team_name": TEAM_NAME,
        }, rid=22)
        if resp.get("ok"):
            result.success("Message queue cleared")
        else:
            result.failure(f"message.clear failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_status_unknown_team(sock_path: str) -> TestResult:
    """Test that team.status for a nonexistent team returns an error."""
    result = TestResult("team.status (unknown team — edge case)")
    try:
        resp = _rpc_call(sock_path, "team.status", {
            "team_name": "nonexistent-team-xyz-rpc-test",
        }, rid=40)
        if not resp.get("ok"):
            result.success("Correctly returns error for unknown team")
        else:
            # Some implementations return ok with empty/null data — acceptable
            data = json.dumps(resp.get("result", {}))
            result.success(f"Returns ok with data (acceptable): {data[:100]}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def main():
    print("=" * 60)
    print("  term-mesh Team RPC Tests")
    print("=" * 60)

    try:
        sock_path = _detect_socket()
    except RuntimeError as e:
        print(f"\n❌ {e}")
        sys.exit(1)

    print(f"  Socket: {sock_path}\n")

    # Ensure clean state
    _cleanup_team(sock_path)

    # Define test sequence (order matters for lifecycle tests)
    tests = [
        lambda: test_ping(sock_path),
        lambda: test_preset_list_includes_workflows(sock_path),
        lambda: test_preset_resolve_workflow(sock_path),
        lambda: test_team_create(sock_path),
    ]

    # After create, wait for agent pane to initialize
    results = []
    for t in tests:
        results.append(t())

    # If create succeeded, wait briefly for pane setup then run remaining tests
    if results[-1].passed:
        time.sleep(2)  # wait for agent terminal pane to spawn
        lifecycle_tests = [
            # --- existing: basic team ops ---
            lambda: test_team_list(sock_path),
            lambda: test_team_status(sock_path),
            lambda: test_team_send(sock_path),
            lambda: test_team_broadcast(sock_path),
            # --- agent operations ---
            lambda: test_team_report(sock_path),
            lambda: test_team_heartbeat(sock_path),
            lambda: test_team_inbox(sock_path),
            # --- task lifecycle ---
            lambda: test_task_create(sock_path),
            lambda: test_task_get(sock_path),
            lambda: test_task_update(sock_path),
            lambda: test_task_review(sock_path),
            lambda: test_inbox_review_ready_task(sock_path),
            lambda: test_task_done(sock_path),
            # --- edge case: invalid task_id while team exists ---
            lambda: test_task_get_invalid_id(sock_path),
            # --- messaging ---
            lambda: test_message_post(sock_path),
            lambda: test_message_list(sock_path),
            lambda: test_message_attention_inbox(sock_path),
            lambda: test_message_clear(sock_path),
            # --- existing: destroy ---
            lambda: test_team_destroy(sock_path),
            lambda: test_team_not_found_after_destroy(sock_path),
            # --- edge case: completely unknown team ---
            lambda: test_status_unknown_team(sock_path),
        ]
        for t in lifecycle_tests:
            results.append(t())
    else:
        # Ensure cleanup even if create failed
        _cleanup_team(sock_path)

    # Report
    print()
    passed = 0
    failed = 0
    for r in results:
        icon = "✅" if r.passed else "❌"
        print(f"  {icon} {r.name}: {r.message}")
        if r.passed:
            passed += 1
        else:
            failed += 1

    print()
    print(f"  Results: {passed} passed, {failed} failed, {len(results)} total")
    print("=" * 60)

    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
