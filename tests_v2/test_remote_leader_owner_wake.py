#!/usr/bin/env python3
"""A remote leader's `tm-agent wait` wakes on the owner's task transition (long-poll).

Regression guard for #785/#789: the remote leader used to sleep until its next
poll, and after #789 every store transition (team.task.done included) must
bump the owner wake. Measured A/B/A2 against forced polling
(TERMMESH_WAIT_PUSH_DISABLE=1) on the staged Rust term-meshd fixture.

Runner-only. Skips unless TERMMESH_E2E_REQUIRE_REMOTE_PROJECT=1 with the
staged fixture env from scripts/run-tests-v2.sh.
"""
from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError
from test_remote_project_restart_reattach import (
    DIR_ENV, HOST_ENV, LEADER_CLI_ENV, REMOTE_FIXTURE_VERSION_ENV,
    REQUIRE_REMOTE_PROJECT_ENV, WORKER_CLI_ENV, _TerminalTestFailure, _assert_leader_relay_stable,
    _canonical_uuid, _connect, _remote_project_manifest_status, _ssh_target,
    _tm_agent_json, _wait, _wait_for_project_deletion,
)


GUI_SESSION_OWNER_FIXTURE_ENV = "TERMMESH_E2E_GUI_SESSION_OWNER_FIXTURE"
FIXTURE_BIN_DIR = "/tmp/term-mesh-release-relay-target/release"
FIXTURE_DAEMON_BIN = f"{FIXTURE_BIN_DIR}/term-meshd"
FIXTURE_TM_AGENT = f"{FIXTURE_BIN_DIR}/tm-agent"
LONG_POLL_MARKER = "waking on owner events (long-poll)"
POLLING_FALLBACK_MARKER = "falling back to polling"

# run_wait polls at once, then sleeps 1, 2, 3, ... s (capped at --interval)
# while nothing settles. Triggering right after poll N leaves an N-second
# sleep ahead, so forced polling (B) must take about N s while a real wake (A)
# answers well inside it. A fixed hold would not work: with this ramp the next
# poll after an 8 s hold is only ~2 s away, and A would pass with no bump.
TRIGGER_AFTER_POLL = 10
WAIT_INTERVAL_S = 30
WAIT_TIMEOUT_S = 240
POLL_REACH_TIMEOUT_S = 180
WAKE_BUDGET_S = 5.0
POLLING_FLOOR_S = TRIGGER_AFTER_POLL - 2.5
MIN_WAKE_ADVANTAGE_S = 2.0
POLL_LINE = re.compile(r"\[\d+/\d+s\] task=(\S+) status=(\S+)")


def fixture_topology_or_skip(label: str) -> tuple[str, str] | None:
    host = os.environ.get(HOST_ENV, "").strip()
    remote_dir = os.environ.get(DIR_ENV, "").strip()
    version = os.environ.get(REMOTE_FIXTURE_VERSION_ENV, "").strip()
    if os.environ.get(REQUIRE_REMOTE_PROJECT_ENV) != "1":
        print(f"SKIP: {label} needs {REQUIRE_REMOTE_PROJECT_ENV}=1 and a staged remote fixture")
        return None
    if not host or not remote_dir or not version:
        raise termmeshError(
            f"required staged fixture topology missing: {HOST_ENV}={host!r} "
            f"{DIR_ENV}={remote_dir!r} {REMOTE_FIXTURE_VERSION_ENV}={version!r}"
        )
    return host, remote_dir


def fixture_root(remote_dir: str) -> str:
    return str(Path(remote_dir).parent)


def remote_python(host: str, script: str, timeout_s: int = 30) -> str:
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", _ssh_target(host), "python3", "-"],
        input=script, capture_output=True, text=True, timeout=timeout_s,
    )
    if result.returncode != 0:
        raise termmeshError(f"remote python3 failed on {host}: {result.stderr.strip()}")
    return result.stdout.strip()


def fixture_daemon_record(host: str, remote_dir: str) -> dict:
    """PID, binary, socket owner, state dir and live socket connects (L4/L10)."""
    root = fixture_root(remote_dir)
    output = remote_python(host, f'''import json, os, pwd, socket, subprocess
root = {root!r}
out = {{"root": root, "state_dir": os.path.join(root, "state")}}
out["state_dir_exists"] = os.path.isdir(out["state_dir"])
out["gui_owner_pid_file"] = os.path.exists(os.path.join(root, "gui.pid"))
try:
    pid = int(open(os.path.join(root, "pid")).read().strip())
except Exception as exc:
    pid = None
    out["pid_error"] = repr(exc)
out["pid"] = pid
if pid is not None:
    try:
        os.kill(pid, 0)
        out["alive"] = True
    except OSError:
        out["alive"] = False
    exe = f"/proc/{{pid}}/exe"
    out["binary"] = os.path.realpath(exe) if os.path.exists(exe) else None
    args = subprocess.run(["ps", "-o", "args=", "-p", str(pid)], capture_output=True, text=True)
    out["args"] = args.stdout.strip()
control = os.path.join(root, "term-meshd.sock")
peer = os.path.join(root, "term-meshd-peer.sock")
for key, path in (("control", control), ("peer", peer)):
    row = {{"path": path}}
    try:
        st = os.stat(path)
        row["owner"] = pwd.getpwuid(st.st_uid).pw_name
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(path)
        s.close()
        row["connect"] = True
    except Exception as exc:
        row["connect"] = False
        row["error"] = repr(exc)
    out[key + "_socket"] = row
owners = None
if os.path.isdir("/proc/self"):
    owners = []
    needle = ("TERMMESH_DAEMON_UNIX_PATH=" + control).encode()
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            env = open(f"/proc/{{entry}}/environ", "rb").read().split(b"\\0")
            exe = os.path.realpath(f"/proc/{{entry}}/exe")
        except Exception:
            continue
        if needle in env and exe.endswith("/term-meshd"):
            try:
                ppid = int(open(f"/proc/{{entry}}/stat").read().rsplit(")", 1)[1].split()[1])
            except Exception:
                ppid = None
            owners.append({{"pid": int(entry), "ppid": ppid}})
out["daemon_owner_pids"] = owners
print(json.dumps(out))
''')
    return json.loads(output)


def gate_g1_rust_fixture(c, host: str, remote_dir: str) -> dict:
    if os.environ.get(GUI_SESSION_OWNER_FIXTURE_ENV, "0").strip() == "1":
        raise termmeshError(
            "G1: GUI session-owner fixture is the wrong topology here; a GUI owner "
            "advertises agent.presentation.v1 and drops the rebuild carry by design"
        )
    row = _connect(c, host)
    root = fixture_root(remote_dir)
    expected_peer = f"{root}/term-meshd-peer.sock"
    if row.get("session_host_socket"):
        raise termmeshError(
            f"G1: host advertises a GUI session owner, not the Rust fixture: row={row!r}"
        )
    if row.get("remote_sock_path") != expected_peer:
        raise termmeshError(
            f"G1: host is not served by the staged Rust fixture socket: "
            f"expected={expected_peer!r} row={row!r}"
        )
    record = fixture_daemon_record(host, remote_dir)
    pid = record.get("pid")
    binary = record.get("binary") or ""
    if not pid or not record.get("alive"):
        raise termmeshError(f"G1: fixture daemon pid is not alive: {record!r}")
    if record.get("gui_owner_pid_file"):
        raise termmeshError(f"G1: a GUI owner fixture is running beside the daemon: {record!r}")
    if binary and binary != FIXTURE_DAEMON_BIN:
        raise termmeshError(f"G1: fixture pid runs a foreign binary: {record!r}")
    if not binary and FIXTURE_DAEMON_BIN not in str(record.get("args") or ""):
        raise termmeshError(f"G1: fixture pid is not the staged term-meshd: {record!r}")
    for key in ("control_socket", "peer_socket"):
        if not (record.get(key) or {}).get("connect"):
            raise termmeshError(f"G1: fixture {key} does not accept a new connect: {record!r}")
    # term-meshd can spawn children from its own executable that inherit its
    # environment, so a second root, not a second process, is the duplicate.
    owners = record.get("daemon_owner_pids")
    if owners is not None:
        owner_pids = {row["pid"] for row in owners}
        roots = sorted(row["pid"] for row in owners if row.get("ppid") not in owner_pids)
        if roots != [pid]:
            raise termmeshError(
                f"G1: control socket does not have exactly one owner daemon (pid file {pid}): {record!r}"
            )
    if not record.get("state_dir_exists"):
        raise termmeshError(f"G1: fixture state dir missing: {record!r}")
    topology = {
        "host": host,
        "serving_app_version": row.get("serving_app_version"),
        "remote_sock_path": row.get("remote_sock_path"),
        "active_sock_path": row.get("active_sock_path"),
        "fixture": record,
        "app_socket": os.environ.get("TERMMESH_SOCKET_PATH") or os.environ.get("TERMMESH_SOCKET"),
        "app_bin": os.environ.get("TERMMESH_APP_BIN"),
    }
    print("TOPOLOGY: " + json.dumps(topology, sort_keys=True))
    return topology


def gate_g2_create_project(c, host: str, remote_dir: str, team: str, roles: list[str]) -> dict:
    leader_cli = os.environ.get(LEADER_CLI_ENV, "claude").strip() or "claude"
    created = c.debug_project_creation_attempt(
        name=team, directory=remote_dir, roles=roles, host=host,
        leader_cli=leader_cli,
        leader_model="gpt-5.6-sol" if leader_cli == "codex" else "sonnet",
        worker_cli=os.environ.get(WORKER_CLI_ENV, "").strip() or None,
    )
    operation_id = str(created.get("operation_id") or "")
    if not operation_id:
        raise termmeshError(f"G2: Project creation returned no operation id: {created!r}")

    def finished():
        status = c.debug_project_creation_status(operation_id)
        if status.get("state") == "failed":
            raise _TerminalTestFailure(f"G2: Project creation failed: {status.get('error')!r}")
        return status if status.get("state") == "created" else None

    status = _wait(finished, timeout_s=240)
    if status is None:
        raise termmeshError(f"G2: Project creation did not complete: operation={operation_id!r}")
    if status.get("working_directory") != remote_dir:
        raise termmeshError(f"G2: Project lost the requested directory: {status!r}")
    return status


def gate_g3_presentation(c, host: str, team: str, roles: list[str]) -> dict:
    def complete():
        matches = [
            item for item in c.debug_project_remote_presentations(host)
            if item.get("name") == team
        ]
        if len(matches) > 1:
            raise _TerminalTestFailure(f"G3: duplicate presentations for {team}: {matches!r}")
        project = matches[0] if matches else None
        if not project or not project.get("project_id") or not project.get("leader_surface_id"):
            return None
        members = project.get("members")
        if not isinstance(members, list) or len(members) != len(roles):
            return None
        return project if all(m.get("surface_id") and m.get("agent_instance_id") for m in members) else None

    project = _wait(complete, timeout_s=90)
    if project is None:
        raise termmeshError(f"G3: no exact remote presentation for {team}")
    return project


def gate_g4_workspace(c, host: str, remote_dir: str, team: str, roles: list[str], project: dict) -> dict:
    def ready_team():
        row = next((item for item in c.team_list() if item.get("team_name") == team), None)
        if row and row.get("leader_failure") and "pending" not in str(row["leader_failure"]).lower():
            raise _TerminalTestFailure(f"G4: remote leader failed: {row['leader_failure']}")
        if row and row.get("remote_attach_failures"):
            raise _TerminalTestFailure(f"G4: remote worker failed: {row['remote_attach_failures']}")
        agents = row.get("agents") if row else None
        agents_ready = (
            isinstance(agents, list) and len(agents) == len(roles)
            and all(a.get("panel_id") and a.get("agent_instance_id") for a in agents)
        )
        return row if row and row.get("leader_ready") and row.get("leader_pane_attached") \
            and row.get("leader_panel_id") and agents_ready else None

    team_row = _wait(ready_team, timeout_s=180)
    if team_row is None:
        raise termmeshError(
            "G4: Project workspace never became ready: "
            f"{next((i for i in c.team_list() if i.get('team_name') == team), None)!r}"
        )
    if len([i for i in c.team_list() if i.get("team_name") == team]) != 1:
        raise termmeshError(f"G4: duplicate local teams for {team}")
    if team_row.get("remote_project_id") != project["project_id"] \
            or team_row.get("remote_project_host") != host:
        raise termmeshError(f"G4: local team differs from the manifest: team={team_row!r} project={project!r}")
    expected = {m["agent_instance_id"] for m in project["members"]}
    actual = {a["agent_instance_id"] for a in team_row["agents"]}
    if expected != actual:
        raise termmeshError(f"G4: member identities differ: manifest={expected!r} team={actual!r}")
    leader_hex = base64.b64decode(project["leader_surface_id"]).hex()
    references = 1 + len(roles)

    def durable_live():
        record = _remote_project_manifest_status(host, remote_dir, project["project_id"])
        if record is None:
            return None
        if record.get("leader_surface_id") != leader_hex:
            raise _TerminalTestFailure(
                f"G4: durable leader surface differs: durable={record!r} expected={leader_hex}"
            )
        return record if int(record.get("referenced_surfaces") or 0) == references \
            and int(record.get("live_surfaces") or 0) == references else None

    if _wait(durable_live, timeout_s=15, interval_s=1) is None:
        raise termmeshError(
            f"G4: durable manifest is not fully live ({references} surfaces): "
            f"{_remote_project_manifest_status(host, remote_dir, project['project_id'])!r}"
        )
    return team_row


def gate_g5_relay(c, host: str, team: str, project: dict) -> dict:
    return _assert_leader_relay_stable(
        c, host, project["project_id"], team, project["leader_surface_id"]
    )


def bring_up_gated_project(c, host: str, remote_dir: str, team: str, roles: list[str]) -> tuple[dict, dict]:
    """G2..G5 in the L8 order, after G1; each gate fails fast with its own message."""
    gate_g2_create_project(c, host, remote_dir, team, roles)
    project = gate_g3_presentation(c, host, team, roles)
    team_row = gate_g4_workspace(c, host, remote_dir, team, roles, project)
    gate_g5_relay(c, host, team, project)
    print(f"GATES: G1-G5 passed team={team} project={project['project_id']}")
    return team_row, project


def delete_project(c, team: str) -> None:
    deletion = c.debug_project_delete(team)
    if operation := str(deletion.get("operation_id") or ""):
        _wait_for_project_deletion(c, operation, timeout_s=90)


def leader_route_file_name(team_uuid: str) -> str:
    identity = f"leader-{team_uuid}".lower()
    return "".join(ch for ch in identity if ch.isascii() and (ch.isalnum() or ch == "-"))[:48] + ".json"


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def remote_wait_command(team: str, team_uuid: str, remote_dir: str, task_id: str, push: bool) -> str:
    control = f"{fixture_root(remote_dir)}/term-meshd.sock"
    route = f'"$HOME/.term-mesh/agent-routes/{leader_route_file_name(team_uuid)}"'
    disable = "" if push else "TERMMESH_WAIT_PUSH_DISABLE=1 "
    return (
        f"route={route}; [ -r \"$route\" ] || exit 70; "
        f"[ -x {FIXTURE_TM_AGENT} ] || exit 72; "
        f"exec timeout {WAIT_TIMEOUT_S + 20} env TERMMESH_SOCKET={shell_quote(control)} "
        f"TERMMESH_SOCKET_PATH={shell_quote(control)} TERMMESH_TEAM={shell_quote(team)} "
        f"TERMMESH_LEADER_ROUTE_FILE=\"$route\" TERMMESH_RPC_TIMEOUT=20 {disable}"
        f"{FIXTURE_TM_AGENT} --team {shell_quote(team)} wait --task {shell_quote(task_id)} "
        f"--mode any --interval {WAIT_INTERVAL_S} --timeout {WAIT_TIMEOUT_S}"
    )


def preflight_leader_route(host: str, team_uuid: str) -> None:
    command = (
        f"route=\"$HOME/.term-mesh/agent-routes/{leader_route_file_name(team_uuid)}\"; "
        f"[ -r \"$route\" ] || exit 70; [ -x {FIXTURE_TM_AGENT} ] || exit 72"
    )
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", _ssh_target(host), command],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode == 70:
        raise termmeshError(f"remote leader route file is not staged for team_uuid={team_uuid}")
    if result.returncode == 72:
        raise termmeshError(f"fixture tm-agent missing: {FIXTURE_TM_AGENT}")
    if result.returncode != 0:
        raise termmeshError(f"leader route preflight failed: {result.stderr.strip()}")


class RemoteWait:
    """One `tm-agent wait` on the fixture host, with timestamped poll lines."""

    def __init__(self, host: str, command: str, task_id: str) -> None:
        self.task_id = task_id
        self.started_at = time.monotonic()
        self.proc = subprocess.Popen(
            ["ssh", "-T", "-o", "BatchMode=yes", _ssh_target(host), command],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
        )
        self.stderr_lines: list[tuple[float, str]] = []
        self.polls: list[float] = []
        self.stdout = ""
        self.exited_at: float | None = None
        self._cond = threading.Condition()
        self._threads = [
            threading.Thread(target=self._read_stderr, daemon=True),
            threading.Thread(target=self._read_stdout, daemon=True),
            threading.Thread(target=self._watch_exit, daemon=True),
        ]
        for thread in self._threads:
            thread.start()

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            now = time.monotonic()
            with self._cond:
                self.stderr_lines.append((now, line.rstrip("\n")))
                match = POLL_LINE.search(line)
                if match and match.group(1) == self.task_id:
                    self.polls.append(now)
                self._cond.notify_all()

    def _read_stdout(self) -> None:
        assert self.proc.stdout is not None
        self.stdout = self.proc.stdout.read()

    def _watch_exit(self) -> None:
        self.proc.wait()
        with self._cond:
            self.exited_at = time.monotonic()
            self._cond.notify_all()

    def wait_for_poll(self, index: int, timeout_s: float) -> float:
        deadline = time.monotonic() + timeout_s
        with self._cond:
            while len(self.polls) < index:
                if self.exited_at is not None:
                    raise termmeshError(
                        f"remote wait exited (rc={self.proc.returncode}) before poll {index}: "
                        f"{self.stderr_text()!r}"
                    )
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise termmeshError(
                        f"remote wait reached only {len(self.polls)} polls in {timeout_s}s: "
                        f"{self.stderr_text()!r}"
                    )
                self._cond.wait(remaining)
            return self.polls[index - 1]

    def wait_exit(self, timeout_s: float) -> float:
        deadline = time.monotonic() + timeout_s
        with self._cond:
            while self.exited_at is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self.proc.kill()
                    raise termmeshError(f"remote wait did not exit in {timeout_s}s: {self.stderr_text()!r}")
                self._cond.wait(remaining)
        for thread in self._threads:
            thread.join(timeout=5)
        return self.exited_at

    def stderr_text(self) -> str:
        return "\n".join(line for _, line in self.stderr_lines)

    def settled_status(self) -> str:
        start = self.stdout.find("{")
        if start < 0:
            return ""
        try:
            payload = json.loads(self.stdout[start:])
        except json.JSONDecodeError:
            return ""
        return str(((payload.get("result") or {}).get("task") or {}).get("status") or "")


def create_unassigned_task(team: str, title: str) -> str:
    created = _tm_agent_json(team, "task", "create", title)
    body = created.get("result") or {}
    task_id = str(body.get("id") or (body.get("task") or {}).get("id") or "")
    if not task_id:
        raise termmeshError(f"task create returned no id: {created!r}")
    return task_id


def measure_wake(
    host: str, team: str, team_uuid: str, remote_dir: str, label: str,
    push: bool, trigger: list[str], expected_status: str,
) -> dict:
    task_id = create_unassigned_task(team, f"owner-wake {label} {uuid.uuid4().hex[:6]}")
    run = RemoteWait(host, remote_wait_command(team, team_uuid, remote_dir, task_id, push), task_id)
    try:
        poll_at = run.wait_for_poll(TRIGGER_AFTER_POLL, timeout_s=POLL_REACH_TIMEOUT_S)
        issued_at = time.monotonic()
        _tm_agent_json(team, "task", *[arg.replace("{id}", task_id) for arg in trigger])
        returned_at = time.monotonic()
        exited_at = run.wait_exit(timeout_s=WAIT_TIMEOUT_S)
    finally:
        if run.proc.poll() is None:
            run.proc.kill()
    stderr = run.stderr_text()
    if run.proc.returncode != 0:
        raise termmeshError(f"{label}: remote wait exited {run.proc.returncode}: {stderr!r}")
    status = run.settled_status()
    if status != expected_status:
        raise termmeshError(f"{label}: wait settled on {status!r}, expected {expected_status!r}: {run.stdout!r}")
    has_marker = LONG_POLL_MARKER in stderr
    if push and not has_marker:
        raise termmeshError(f"{label}: remote leader did not take the owner long-poll path: {stderr!r}")
    if push and POLLING_FALLBACK_MARKER in stderr:
        raise termmeshError(f"{label}: owner wake thread exited and wait fell back to polling: {stderr!r}")
    if not push and has_marker:
        raise termmeshError(f"{label}: TERMMESH_WAIT_PUSH_DISABLE=1 still used the long-poll: {stderr!r}")
    polls = run.polls
    return {
        "label": label,
        "task_id": task_id,
        "push": push,
        "trigger": trigger[0],
        "poll_index": TRIGGER_AFTER_POLL,
        "poll_gaps_s": [round(b - a, 3) for a, b in zip(polls, polls[1:])],
        "trigger_rpc_s": round(returned_at - issued_at, 3),
        "after_poll_s": round(issued_at - poll_at, 3),
        "latency_from_issue_s": round(exited_at - issued_at, 3),
        "latency_from_return_s": round(exited_at - returned_at, 3),
    }


def assert_woken(run: dict) -> None:
    if run["latency_from_issue_s"] > WAKE_BUDGET_S:
        raise termmeshError(
            f"{run['label']}: trigger did not reach a bump site, or the owner wake was not "
            f"delivered: wait exited {run['latency_from_issue_s']}s after {run['trigger']} "
            f"(budget {WAKE_BUDGET_S}s): {run!r}"
        )


def main() -> int:
    topology = fixture_topology_or_skip("remote leader owner wake")
    if topology is None:
        return 0
    host, remote_dir = topology
    team = f"owner-wake-e2e-{uuid.uuid4().hex[:8]}"
    roles = ["executor"]
    with termmesh() as c:
        gate_g1_rust_fixture(c, host, remote_dir)
        try:
            team_row, _project = bring_up_gated_project(c, host, remote_dir, team, roles)
            team_uuid = _canonical_uuid(team_row.get("team_uuid"))
            preflight_leader_route(host, team_uuid)

            done = ["done", "{id}", "owner-wake e2e"]
            run_a = measure_wake(host, team, team_uuid, remote_dir, "A", True, done, "completed")
            assert_woken(run_a)
            run_b = measure_wake(host, team, team_uuid, remote_dir, "B", False, done, "completed")
            if run_b["latency_from_return_s"] < POLLING_FLOOR_S:
                raise termmeshError(
                    "B: forced polling exited sooner than its scheduled poll, so A's speed "
                    f"proves nothing (floor {POLLING_FLOOR_S}s): {run_b!r}"
                )
            run_a2 = measure_wake(host, team, team_uuid, remote_dir, "A2", True, done, "completed")
            assert_woken(run_a2)
            for run in (run_a, run_a2):
                if run_b["latency_from_return_s"] - run["latency_from_issue_s"] < MIN_WAKE_ADVANTAGE_S:
                    raise termmeshError(
                        f"{run['label']} is not measurably faster than polling: A={run!r} B={run_b!r}"
                    )
            update = ["update", "{id}", "completed"]
            run_u = measure_wake(host, team, team_uuid, remote_dir, "U", True, update, "completed")
            assert_woken(run_u)
            print("RESULT: " + json.dumps({"A": run_a, "B": run_b, "A2": run_a2, "U": run_u}, sort_keys=True))
        finally:
            delete_project(c, team)

    print(
        "PASS: remote leader wait wakes on team.task.done and team.task.update "
        f"within {WAKE_BUDGET_S}s (A/A2) while forced polling waits its schedule (B)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
