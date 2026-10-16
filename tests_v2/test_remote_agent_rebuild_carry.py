#!/usr/bin/env python3
"""A peer-owned native worker's task survives a mid-turn pane rebuild, or is blocked once.

Evidence run for #786/#788, not a merge gate: the worker is a real LLM, so the
turn timing is nondeterministic. `peer.host.reconnect` drops the worker pane
with "host reconnected" while its turn runs `sleep 45`. The task must then end
either completed by the rebuilt pane's STATUS: DONE <nonce> (carry installed)
or blocked exactly once with the rebuild reason (carry impossible) — never
left in_progress.

Runs only with TERMMESH_E2E_LLM_WORKER=1 on the staged Rust term-meshd fixture
(TERMMESH_E2E_REQUIRE_REMOTE_PROJECT=1). TERMMESH_E2E_REQUIRE_CARRY=1 rejects
the blocked outcome.
"""
from __future__ import annotations

import json
import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError
from test_remote_project_restart_reattach import (
    _TerminalTestFailure, _debug_log_candidates, _tm_agent_json, _wait,
)
from test_remote_leader_owner_wake import (
    bring_up_gated_project, delete_project, fixture_topology_or_skip,
    gate_g1_rust_fixture,
)


LLM_WORKER_ENV = "TERMMESH_E2E_LLM_WORKER"
REQUIRE_CARRY_ENV = "TERMMESH_E2E_REQUIRE_CARRY"
REBUILD_LOSS_MARKER = "the pane was rebuilt (host reconnected)"
CORRELATION_LOST = "agent.task.correlation.lost"
TERMINAL_STATUSES = {"completed", "blocked", "failed", "cancelled", "review_ready"}
WORKER_SLEEP_S = 120
OPEN_STATUSES = ("assigned", "in_progress")
# The rebuild must land inside the worker's `sleep`, after the turn is
# visibly running; well short of WORKER_SLEEP_S leaves room for model latency.
REBUILD_AFTER_IN_PROGRESS_S = 12
BLOCKED_HOLD_S = 15
CONTROL_HOLD_S = 20


class DebugLogCounter:
    """Counts marker lines appended to the app's own debug log after creation."""

    def __init__(self) -> None:
        self._baselines: dict[Path, int] = {}
        deadline = time.time() + 5
        while not self._baselines and time.time() < deadline:
            for path in _debug_log_candidates():
                try:
                    self._baselines[path] = path.stat().st_size
                except OSError:
                    continue
            if not self._baselines:
                time.sleep(0.2)
        if not self._baselines:
            raise termmeshError(
                "no app debug log resolved; the carry evidence needs the DEBUG build's "
                f"{CORRELATION_LOST} lines (set TERMMESH_DEBUG_LOG)"
            )

    def count(self, needle: str) -> int:
        total = 0
        for path, baseline in self._baselines.items():
            try:
                size = path.stat().st_size
                with path.open("rb") as handle:
                    handle.seek(baseline if size >= baseline else 0)
                    text = handle.read().decode("utf-8", "replace")
            except OSError:
                continue
            total += sum(1 for line in text.splitlines() if needle in line)
        return total


def team_row(c, team: str) -> dict:
    row = next((item for item in c.team_list() if item.get("team_name") == team), None)
    if row is None:
        raise termmeshError(f"team disappeared: {team}")
    return row


def agent_row(c, team: str, instance_id: str) -> dict:
    return next(
        (a for a in team_row(c, team).get("agents") or []
         if a.get("agent_instance_id") == instance_id),
        None,
    ) or {}


def agent_panel(c, team: str, instance_id: str) -> str:
    return str(agent_row(c, team, instance_id).get("panel_id") or "")


def member_surface(c, host: str, team: str, instance_id: str) -> str:
    project = next(
        (p for p in c.debug_project_remote_presentations(host) if p.get("name") == team),
        None,
    )
    member = next(
        (m for m in (project or {}).get("members") or []
         if m.get("agent_instance_id") == instance_id),
        None,
    )
    return str((member or {}).get("surface_id") or "")


def task_by_id(c, team: str, task_id: str) -> dict:
    task = next((t for t in c.team_task_list(team) if t.get("id") == task_id), None)
    if task is None:
        raise termmeshError(f"task {task_id} vanished from {team}")
    return task


def force_rebuild(c, host: str, team: str, instance_id: str, surface_id: str, old_panel: str) -> dict:
    reply = c.peer_host_reconnect(host)
    if not reply.get("started", True) and reply.get("state") != "connected":
        raise termmeshError(f"peer.host.reconnect did not start: {reply!r}")

    def rebuilt():
        panel = agent_panel(c, team, instance_id)
        if not panel or panel == old_panel:
            return None
        current = member_surface(c, host, team, instance_id)
        if not current:
            return None
        if current != surface_id:
            raise _TerminalTestFailure(
                f"rebuild changed the worker surface: expected={surface_id!r} now={current!r}"
            )
        sessions = c.peer_pane_status().get("pane_sessions") or []
        live = [s for s in sessions if s.get("surface_id") == surface_id and not s.get("torn_down")]
        return {"panel_id": panel, "relay": live[0]} if live else None

    result = _wait(rebuilt, timeout_s=120, interval_s=0.5)
    if result is None:
        raise termmeshError(
            f"worker pane was not rebuilt on the same surface after reconnect: "
            f"old_panel={old_panel} now={agent_panel(c, team, instance_id)!r} reply={reply!r}"
        )
    return {"reconnect": reply, **result}


def main() -> int:
    if os.environ.get(LLM_WORKER_ENV) != "1":
        print(f"SKIP: rebuild carry drives a real LLM worker; set {LLM_WORKER_ENV}=1")
        return 0
    topology = fixture_topology_or_skip("remote agent rebuild carry")
    if topology is None:
        return 0
    host, remote_dir = topology
    team = f"rebuild-carry-e2e-{uuid.uuid4().hex[:8]}"
    roles = ["executor"]
    nonce = f"CARRY-{uuid.uuid4().hex[:10]}"
    evidence: dict = {"team": team, "nonce": nonce}
    with termmesh() as c:
        gate_g1_rust_fixture(c, host, remote_dir)
        try:
            row, project = bring_up_gated_project(c, host, remote_dir, team, roles)
            agent = row["agents"][0]
            instance_id = str(agent["agent_instance_id"])
            surface_id = member_surface(c, host, team, instance_id)
            if not surface_id:
                raise termmeshError(f"worker has no manifest surface: {project!r}")
            log = DebugLogCounter()

            delegated = _tm_agent_json(
                team, "delegate", str(agent["name"]),
                "E2E rebuild-carry probe. Use the Bash tool once with run_in_background set to "
                f"true to run: python3 -c \"import time; time.sleep({WORKER_SLEEP_S})\" . Then end "
                "your turn right away by saying 'waiting'. Do not poll, sleep, or use Monitor. Do "
                "not edit files. When you are notified that the background job finished, reply "
                f"with exactly one line: STATUS: DONE {nonce}",
                "--worktree", "off", "--title", f"rebuild carry {nonce}",
            )
            task_id = str((delegated.get("result") or {}).get("task", {}).get("id") or "")
            if not task_id:
                raise termmeshError(f"delegate returned no task id: {delegated!r}")
            evidence["task_id"] = task_id

            # A native worker's task stays `assigned` until a verdict settles it;
            # agent_state "running" is the turn actually in flight.
            def running():
                task = task_by_id(c, team, task_id)
                if task.get("status") in TERMINAL_STATUSES:
                    raise _TerminalTestFailure(f"task settled before the rebuild could land: {task!r}")
                state = agent_row(c, team, instance_id).get("agent_state")
                return task if task.get("status") in OPEN_STATUSES and state == "running" else None

            # A cold remote worker can take minutes to start its first turn.
            if _wait(running, timeout_s=480, interval_s=0.5) is None:
                raise termmeshError(f"worker never started task {task_id}: {task_by_id(c, team, task_id)!r}")

            # The carried case: the worker handed its job to the background and
            # ended the turn, so the task is pending with no turn in flight.
            def idle_with_pending_task():
                task = task_by_id(c, team, task_id)
                if task.get("status") in TERMINAL_STATUSES:
                    raise _TerminalTestFailure(f"task settled before the rebuild could land: {task!r}")
                state = agent_row(c, team, instance_id).get("agent_state")
                return task if task.get("status") in OPEN_STATUSES and state != "running" else None

            if _wait(idle_with_pending_task, timeout_s=180, interval_s=1) is None:
                raise termmeshError(f"worker never ended its first turn: {task_by_id(c, team, task_id)!r}")
            time.sleep(REBUILD_AFTER_IN_PROGRESS_S)
            before = task_by_id(c, team, task_id)
            agent_state = agent_row(c, team, instance_id).get("agent_state")
            if before.get("status") not in OPEN_STATUSES:
                raise termmeshError(f"task settled before the rebuild: {before!r}")
            evidence["agent_state_at_rebuild"] = agent_state

            old_panel = agent_panel(c, team, instance_id)
            rebuild_started = time.monotonic()
            evidence["rebuild"] = force_rebuild(c, host, team, instance_id, surface_id, old_panel)
            evidence["rebuild"]["old_panel_id"] = old_panel
            evidence["rebuild"]["surface_id"] = surface_id

            def settled():
                task = task_by_id(c, team, task_id)
                return task if task.get("status") in TERMINAL_STATUSES else None

            final = _wait(settled, timeout_s=360, interval_s=1)
            if final is None:
                raise termmeshError(
                    "task is silently stuck after the pane rebuild: "
                    f"{task_by_id(c, team, task_id)!r}"
                )
            evidence["settle_after_rebuild_s"] = round(time.monotonic() - rebuild_started, 1)
            lost = log.count(f"{CORRELATION_LOST} task={task_id}")
            evidence["correlation_lost_lines"] = lost
            status = final.get("status")
            reason = str(final.get("blocked_reason") or "")
            if status == "completed":
                if nonce not in str(final.get("result") or ""):
                    raise termmeshError(f"completed without the rebuilt pane's nonce: {final!r}")
                if reason or lost:
                    raise termmeshError(f"carried task also recorded a loss (lost={lost}): {final!r}")
                evidence["outcome"] = "carried"
            elif status == "blocked" and REBUILD_LOSS_MARKER in reason:
                if lost != 1:
                    raise termmeshError(f"rebuild loss was reported {lost} times, expected once: {final!r}")

                def still_blocked_once():
                    task = task_by_id(c, team, task_id)
                    if task.get("status") != "blocked" or task.get("blocked_reason") != reason:
                        raise termmeshError(f"blocked task changed after the loss: {task!r}")
                    if log.count(f"{CORRELATION_LOST} task={task_id}") != 1:
                        raise termmeshError("rebuild loss was reported again during the hold")

                hold_until = time.monotonic() + BLOCKED_HOLD_S
                while time.monotonic() < hold_until:
                    still_blocked_once()
                    time.sleep(1)
                evidence["outcome"] = "lost_once"
                evidence["blocked_reason"] = reason
            else:
                raise termmeshError(f"task ended in an unexpected state after the rebuild: {final!r}")
            if os.environ.get(REQUIRE_CARRY_ENV) == "1" and evidence["outcome"] != "carried":
                raise termmeshError(f"{REQUIRE_CARRY_ENV}=1 but the carry was lost: {final!r}")

            control_log = DebugLogCounter()
            statuses = {t.get("id"): t.get("status") for t in c.team_task_list(team)}
            control_panel = agent_panel(c, team, instance_id)
            evidence["control"] = force_rebuild(c, host, team, instance_id, surface_id, control_panel)
            hold_until = time.monotonic() + CONTROL_HOLD_S
            while time.monotonic() < hold_until:
                for task in c.team_task_list(team):
                    if task.get("status") == "blocked" and statuses.get(task.get("id")) != "blocked":
                        raise termmeshError(f"control rebuild with no pending task blocked a task: {task!r}")
                if control_log.count(CORRELATION_LOST):
                    raise termmeshError("control rebuild with no pending task reported a correlation loss")
                time.sleep(1)
            print("EVIDENCE: " + json.dumps(evidence, sort_keys=True, default=str))
        finally:
            delete_project(c, team)

    print(
        f"PASS: mid-turn pane rebuild ended the task as {evidence.get('outcome')} "
        "(never stuck) and an idle rebuild blocked nothing"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
