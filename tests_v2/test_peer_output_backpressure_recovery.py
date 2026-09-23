#!/usr/bin/env python3
"""Incident-shaped heavy-output gate for a staged remote Project route."""

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError
from test_remote_project_restart_reattach import _assert_session_owner_route, _connect

MAX_RECONNECT_ATTEMPTS = 8
MAX_FD_GROWTH = 64
OUTPUT_BYTES = 2 * 1024 * 1024
OUTPUT_BURSTS = 8
GUI_OUTPUT_BYTES = 4 * 1024 * 1024
GUI_OUTPUT_BURSTS = 8
POLL_INTERVAL_SECONDS = 0.25
REQUIRED_ENV = (
    "TERMMESH_E2E_REQUIRE_REMOTE_PROJECT",
    "TERMMESH_E2E_REATTACH_PHASE",
    "TERMMESH_E2E_STAGE_REMOTE_FIXTURE",
    "TERMMESH_E2E_CANDIDATE_SHA",
    "TERMMESH_E2E_REMOTE_FIXTURE_CANDIDATE_SHA",
    "TERMMESH_E2E_REMOTE_FIXTURE_VERSION",
    "TERMMESH_E2E_REMOTE_LEADER_HOST",
    "TERMMESH_E2E_REMOTE_LEADER_DIR",
    "TERMMESH_E2E_REMOTE_LEADER_HOST_PROFILE_JSON",
)


def _wait(predicate, timeout_s: float = 45.0):
    deadline = time.time() + timeout_s
    last = None
    while time.time() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(POLL_INTERVAL_SECONDS)
    return None


def _env_value(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise termmeshError(f"required topology variable is missing: {name}")
    return value


def _validate_topology() -> Dict[str, str]:
    values = {name: _env_value(name) for name in REQUIRED_ENV}
    if values["TERMMESH_E2E_REQUIRE_REMOTE_PROJECT"] != "1":
        raise termmeshError("remote Project topology is not required")
    if values["TERMMESH_E2E_REATTACH_PHASE"] != "full":
        raise termmeshError("backpressure recovery requires the full staged topology")
    if values["TERMMESH_E2E_STAGE_REMOTE_FIXTURE"] != "1":
        raise termmeshError("remote fixture was not staged from the candidate")
    if values["TERMMESH_E2E_CANDIDATE_SHA"] != values["TERMMESH_E2E_REMOTE_FIXTURE_CANDIDATE_SHA"]:
        raise termmeshError("viewer and daemon candidate SHAs differ")
    if not values["TERMMESH_E2E_REMOTE_LEADER_HOST"].startswith("ssh:"):
        raise termmeshError("remote Project host is not an SSH stable id")
    try:
        profiles = json.loads(values["TERMMESH_E2E_REMOTE_LEADER_HOST_PROFILE_JSON"])
    except ValueError as exc:
        raise termmeshError(f"remote host profile JSON is invalid: {exc}") from exc
    if not isinstance(profiles, list) or not profiles:
        raise termmeshError("remote host profile JSON is empty")
    target = values["TERMMESH_E2E_REMOTE_LEADER_HOST"][len("ssh:"):]
    if not any(str(row.get("sshTarget") or "") == target for row in profiles if isinstance(row, dict)):
        raise termmeshError("remote host profile does not match the staged host")
    return values


def _assert_route(row: Dict[str, Any], expected_version: str) -> Dict[str, Any]:
    if str(row.get("serving_app_version") or "") != expected_version:
        raise termmeshError(
            f"serving version mismatch: expected={expected_version!r} row={row!r}"
        )
    if not row.get("durable_remote_creation"):
        raise termmeshError(f"Project capability is not advertised: row={row!r}")
    if not row.get("authoritative_leader_liveness"):
        raise termmeshError(f"leader liveness capability is not advertised: row={row!r}")
    serving = str(row.get("remote_sock_path") or "")
    owner = str(row.get("session_host_socket") or "")
    if not serving:
        raise termmeshError(f"GUI serving endpoint provenance is missing: row={row!r}")
    if owner:
        route = _assert_session_owner_route(row)
        route["kind"] = "gui_with_session_owner"
        return route
    if os.environ.get("TERMMESH_E2E_REQUIRE_SESSION_OWNER_REDIRECT") == "1":
        raise termmeshError(
            f"daemon-only route cannot satisfy the required GUI/session-owner topology: row={row!r}"
        )
    if row.get("team_host_readiness") != "ready":
        raise termmeshError(f"daemon-only route is not explicitly ready: row={row!r}")
    return {
        "kind": "daemon_only",
        "serving_socket": serving,
        "session_owner_socket": serving,
        "team_host_endpoint": str(row.get("team_host_endpoint") or ""),
    }


def _manifest(client, host: str, project_id: str, leader_surface: str, members: Dict[str, Dict[str, str]]) -> Optional[dict]:
    for project in client.debug_project_remote_presentations(host):
        if project.get("project_id") != project_id:
            continue
        if project.get("leader_surface_id") != leader_surface:
            continue
        actual = {
            str(member.get("name") or ""): member
            for member in project.get("members") or []
        }
        if all(
            actual.get(name, {}).get("agent_instance_id") == expected["agent_instance_id"]
            and actual.get(name, {}).get("surface_id") == expected["surface_id"]
            for name, expected in members.items()
        ):
            return project
    return None


def _pane_status(client, surface_id: str) -> Optional[dict]:
    return next(
        (row for row in client.peer_pane_status().get("pane_sessions") or []
         if row.get("surface_id") == surface_id),
        None,
    )


def _process_evidence() -> Dict[str, Any]:
    pid_file = _env_value("TERMMESH_E2E_APP_PID_FILE")
    try:
        pid = int(Path(pid_file).read_text().strip())
    except (OSError, ValueError) as exc:
        raise termmeshError(f"GUI app PID evidence is unavailable: {exc}") from exc
    binary = _env_value("TERMMESH_APP_BIN")
    if not Path(binary).exists():
        raise termmeshError(f"GUI app binary evidence is unavailable: {binary}")
    return {"pid": pid, "binary_path": binary, "fd_count": _fd_count(pid), "peer_sockets": _peer_sockets(pid)}


def _fd_count(pid: int) -> int:
    result = subprocess.run(["lsof", "-p", str(pid)], capture_output=True, text=True, timeout=10)
    if result.returncode not in (0, 1):
        raise termmeshError(f"cannot measure GUI FD count: {result.stderr.strip()}")
    return max(0, len(result.stdout.splitlines()) - 1)


def _peer_sockets(pid: int) -> List[str]:
    result = subprocess.run(["lsof", "-a", "-p", str(pid), "-U", "-F", "fn"], capture_output=True, text=True, timeout=10)
    if result.returncode not in (0, 1):
        raise termmeshError(f"cannot inspect GUI peer socket ownership: {result.stderr.strip()}")
    sockets: List[str] = []
    fd = ""
    for line in result.stdout.splitlines():
        if line.startswith("f"):
            fd = line[1:]
        elif line.startswith("n") and line[1:]:
            sockets.append(f"fd={fd}:{line[1:]}")
    return sockets


def _count_markers(path: str, offset: int) -> Dict[str, int]:
    try:
        data = Path(path).read_bytes()[offset:].decode("utf-8", "replace")
    except OSError:
        data = ""
    return {
        "unexpected_eof": data.count("unexpectedEof"),
        "overflow_episodes": data.count("overflow-episode"),
        "queue_drops": data.count("queue-drop"),
        "attachment_aborts": data.count("attachment-abort"),
        "snapshot_heals": data.count("snapshot-heal"),
        "write_errors": data.count("write-error"),
        "pty_write_errors": data.count("pty-write-error"),
        "writer_ended": data.count("pty-writer-ended"),
    }


def _run_gui_listener_stress(client, process: Dict[str, Any], log_path: str, log_offset: int) -> Dict[str, Any]:
    source_surface = client.new_surface(panel_type="terminal")
    remote_panel = None
    try:
        def source_ready():
            try:
                return bool(client.read_terminal_text(source_surface).strip())
            except termmeshError as exc:
                if exc.code == "unavailable" and "retryable" in str(exc):
                    return False
                raise

        if _wait(source_ready, timeout_s=30) is None:
            raise termmeshError("GUI listener stress source terminal never became ready")
        client.focus_surface(source_surface)
        opened = client.peer_open_remote_pane()
        if not opened.get("started"):
            raise termmeshError(f"GUI loopback remote pane did not start: {opened!r}")

        def open_result():
            result = client.peer_pane_status().get("last_open_result")
            return result if isinstance(result, dict) else None

        result = _wait(open_result, timeout_s=60)
        if result is None or not result.get("ok"):
            raise termmeshError(f"GUI loopback remote pane failed: {result!r}")
        remote_panel = str(result.get("panel_id") or "")
        if not remote_panel:
            raise termmeshError(f"GUI loopback remote pane returned no panel: {result!r}")

        app_peer_path = os.environ.get("TERMMESH_PEER_SERVER_PATH", "").strip()
        if not app_peer_path:
            daemon_path = os.environ.get("TERMMESH_DAEMON_UNIX_PATH", "").strip()
            if daemon_path.endswith(".sock"):
                app_peer_path = daemon_path[:-5] + "-app-peer.sock"
        sessions = [
            row for row in client.peer_pane_status().get("pane_sessions") or []
            if str(row.get("host_key") or "") == app_peer_path
        ]
        if len(sessions) != 1:
            raise termmeshError(f"GUI loopback attach count is not one: {sessions!r}")
        try:
            source_id = str(uuid.UUID(bytes=base64.b64decode(sessions[0]["surface_id"])))
        except (KeyError, ValueError, TypeError) as exc:
            raise termmeshError(f"GUI loopback source surface identity is invalid: {sessions!r}") from exc

        before = next(
            (row for row in client.peer_pane_status().get("pane_sessions") or []
             if row.get("surface_id") == sessions[0].get("surface_id")),
            {},
        )
        io_before = dict(before.get("io") or {})
        marker = f"GUI_BACKPRESSURE_DONE_{uuid.uuid4().hex[:10]}"
        burst_command = "; ".join(
            f"yes | head -c {GUI_OUTPUT_BYTES}"
            for _ in range(GUI_OUTPUT_BURSTS)
        )
        client.send_surface(source_id, f"{burst_command}; printf '\n{marker}\n'\r")

        deadline = time.time() + 90
        max_fd = int(process["fd_count"])
        final = None
        attachment_failed = False
        marker_seen = False
        while time.time() < deadline:
            current = next(
                (row for row in client.peer_pane_status().get("pane_sessions") or []
                 if row.get("surface_id") == sessions[0].get("surface_id")),
                None,
            )
            if current is None:
                attachment_failed = True
                break
            final = current
            max_fd = max(max_fd, _fd_count(process["pid"]))
            if marker in client.read_terminal_text(remote_panel):
                marker_seen = True
                break
            time.sleep(POLL_INTERVAL_SECONDS)
        if not marker_seen and final is not None:
            attachment_failed = bool(
                final.get("torn_down") or final.get("relay_liveness") == "ended"
            )
        live_progress = bool(
            final
            and final.get("relay_liveness") == "live"
            and not final.get("torn_down")
            and int((final.get("io") or {}).get("bytes_received") or 0)
            > int(io_before.get("bytes_received") or 0)
            and int((final.get("io") or {}).get("bytes_enqueued") or 0)
            > int(io_before.get("bytes_enqueued") or 0)
        )
        if not marker_seen and not attachment_failed and not live_progress:
            raise termmeshError(
                "GUI loopback heavy-output neither converged nor failed boundedly: "
                f"pane={final!r} source={source_surface!r} remote_panel={remote_panel!r}"
            )
        time.sleep(1.0)
        final = next(
            (row for row in client.peer_pane_status().get("pane_sessions") or []
             if row.get("surface_id") == sessions[0].get("surface_id")),
            final,
        ) if final is not None else None
        io_after = dict((final or {}).get("io") or {})
        markers = _count_markers(log_path, log_offset)
        boundary_observed = (
            markers["overflow_episodes"] > 0
            or markers["queue_drops"] > 0
            or int(io_after.get("bytes_dropped") or 0) > int(io_before.get("bytes_dropped") or 0)
            or int(io_after.get("resume_gate_buffered_bytes") or 0) > 0
        )
        bounded_failure_observed = attachment_failed and (
            markers["pty_write_errors"] > 0
            or markers["write_errors"] > 0
            or markers["writer_ended"] > 0
        )
        if (marker_seen or live_progress) and final and (
            int((io_after or {}).get("bytes_received") or 0)
            <= int((io_before or {}).get("bytes_received") or 0)
            or final.get("torn_down")
            or final.get("relay_liveness") != "live"
        ):
            raise termmeshError(
                "GUI loopback relay did not converge live: "
                f"before={io_before!r} after={io_after!r} final={final!r}"
            )
        return {
            "source_surface_id": source_id,
            "remote_panel_id": remote_panel,
            "before_io": io_before,
            "after_io": io_after,
            "final_relay": final,
            "log_markers": markers,
            "outcome": "resync" if marker_seen else ("live_progress" if live_progress else "bounded_attachment_failure"),
            "fd_baseline": int(process["fd_count"]),
            "fd_max": max_fd,
            "output_bytes_per_burst": GUI_OUTPUT_BYTES,
            "output_bursts": GUI_OUTPUT_BURSTS,
            "queue_boundary_observed": boundary_observed,
            "bounded_attachment_failure_observed": bounded_failure_observed,
        }
    finally:
        if remote_panel:
            try:
                client.close_surface(remote_panel)
            except Exception:
                pass
        try:
            client.close_surface(source_surface)
        except Exception:
            pass


def _dry_run() -> int:
    required = {
        "bytes_received", "bytes_enqueued", "reconnect_attempts",
        "reconnect_cooldowns", "reconnect_circuit",
    }
    sample = {key: 0 for key in required}
    if not required.issubset(sample):
        raise termmeshError("backpressure telemetry contract is incomplete")
    assert _assert_route(
        {
            "serving_app_version": "v0.1.0",
            "durable_remote_creation": True,
            "authoritative_leader_liveness": True,
            "remote_sock_path": "/tmp/gui.sock",
            "session_host_socket": "/tmp/daemon.sock",
            "team_host_endpoint": "ssh:mac:/tmp/daemon.sock",
            "team_host_readiness": "ready",
        },
        "v0.1.0",
    )["kind"] == "gui_with_session_owner"
    print("PASS: backpressure recovery import and topology/telemetry contract dry-run")
    return 0


def _run() -> int:
    values = _validate_topology()
    host = values["TERMMESH_E2E_REMOTE_LEADER_HOST"]
    remote_dir = values["TERMMESH_E2E_REMOTE_LEADER_DIR"]
    expected_version = values["TERMMESH_E2E_REMOTE_FIXTURE_VERSION"]
    team_name = f"relay-backpressure-{uuid.uuid4().hex[:8]}"
    state_dir = _env_value("TERMMESH_E2E_STATE_DIR")
    log_path = "/tmp/term-mesh-peer-server.log"
    try:
        log_offset = Path(log_path).stat().st_size
    except OSError:
        log_offset = 0
    evidence: Dict[str, Any] = {
        "candidate_sha": values["TERMMESH_E2E_CANDIDATE_SHA"],
        "remote_fixture_candidate_sha": values["TERMMESH_E2E_REMOTE_FIXTURE_CANDIDATE_SHA"],
        "remote_fixture_version": expected_version,
        "state_directory": state_dir,
        "host": host,
        "project": {"team_name": team_name, "directory": remote_dir},
        "cleanup_receipt": {"requested": False, "completed": False},
    }
    state = None
    cleaned = False
    with termmesh() as client:
        try:
            row = _connect(client, host)
            evidence["route"] = _assert_route(row, expected_version)
            process = _process_evidence()
            evidence["viewer"] = process
            if not process["peer_sockets"]:
                raise termmeshError("GUI peer listener ownership is not observable")

            created = client.debug_project_creation_attempt(
                name=team_name, directory=remote_dir, roles=["executor"],
                host=host, leader_cli=os.environ.get("TERMMESH_E2E_REMOTE_LEADER_CLI", "claude"),
            )
            operation_id = str(created.get("operation_id") or "")
            if not operation_id:
                raise termmeshError(f"remote Project creation returned no operation id: {created!r}")

            def creation_finished():
                status = client.debug_project_creation_status(operation_id)
                if status.get("state") == "failed":
                    raise termmeshError(f"remote Project creation failed: {status!r}")
                return status if status.get("state") == "created" else None

            bootstrap = _wait(creation_finished, timeout_s=240)
            if bootstrap is None:
                raise termmeshError("remote Project creation timed out")
            project_id = str(bootstrap.get("project_id") or "")

            def ready_team():
                team = next((item for item in client.team_list() if item.get("team_name") == team_name), None)
                if team and team.get("leader_failure") and "pending" not in str(team["leader_failure"]).lower():
                    raise termmeshError(f"remote leader failed: {team!r}")
                agents = team.get("agents") if team else []
                return team if team and team.get("leader_ready") and team.get("leader_pane_attached") and len(agents) == 1 and agents[0].get("panel_id") and agents[0].get("agent_instance_id") else None

            team = _wait(ready_team, timeout_s=90)
            if team is None:
                raise termmeshError("remote Project did not reach leader/member readiness")
            project_id = project_id or str(team.get("remote_project_id") or "")
            leader_panel = str(team.get("leader_panel_id") or "")
            member = team["agents"][0]
            member_name = str(member["name"])
            workspace_id = str(team.get("workspace_id") or "")
            pane_ids = [leader_panel] + [str(agent.get("panel_id") or "") for agent in team.get("agents") or []]
            if not workspace_id or not leader_panel or any(not pane_id for pane_id in pane_ids) or not member.get("agent_instance_id"):
                raise termmeshError(f"Project leader/member surface identity is incomplete: {team!r}")
            if not project_id:
                project_id = next(
                    (str(item.get("project_id") or "")
                     for item in client.debug_project_remote_presentations(host)
                     if item.get("name") == team_name),
                    "",
                )
            if not project_id:
                raise termmeshError(f"remote Project manifest returned no project id: {team!r}")
            published = _wait(
                lambda: next(
                    (item for item in client.debug_project_remote_presentations(host)
                     if item.get("project_id") == project_id
                     and item.get("name") == team_name
                     and item.get("leader_surface_id")
                     and any(str(row.get("name") or "") == member_name
                             and row.get("agent_instance_id")
                             and row.get("surface_id")
                             for row in item.get("members") or [])),
                    None,
                ),
                timeout_s=45,
            )
            if published is None:
                raise termmeshError("remote Project manifest did not publish exact surface identity")
            leader_surface = str(published["leader_surface_id"])
            published_members = {
                str(row.get("name") or ""): row
                for row in published.get("members") or []
            }
            published_member = published_members.get(member_name)
            if published_member is None or str(published_member.get("agent_instance_id") or "") != str(member["agent_instance_id"]):
                raise termmeshError(f"Project manifest member identity differs from team summary: {published!r}")
            members = {
                member_name: {
                    "agent_instance_id": str(published_member["agent_instance_id"]),
                    "surface_id": str(published_member["surface_id"]),
                    "pane_id": str(member.get("panel_id") or ""),
                }
            }
            state = {"project_id": project_id, "team_name": team_name, "workspace_id": workspace_id, "leader_surface_id": leader_surface, "leader_panel_id": leader_panel, "pane_ids": pane_ids, "members": members}
            manifest = _wait(lambda: _manifest(client, host, project_id, leader_surface, members), timeout_s=45)
            if manifest is None:
                raise termmeshError("exact Project manifest was not published")
            evidence["project"].update(state)
            evidence["manifest"] = manifest

            gui_stress = _run_gui_listener_stress(client, process, log_path, log_offset)
            evidence["gui_listener_stress"] = gui_stress

            before = _pane_status(client, leader_surface)
            if before is None:
                raise termmeshError(f"leader relay is not observable: surface={leader_surface}")
            io_before = before.get("io") or {}
            for key in ("bytes_received", "bytes_enqueued", "reconnect_attempts", "reconnect_cooldowns", "reconnect_circuit"):
                if key not in io_before:
                    raise termmeshError(f"candidate relay telemetry is missing {key!r}: {io_before!r}")
            stress_process = _process_evidence()
            fd_baseline = int(stress_process["fd_count"])
            max_fd = fd_baseline
            max_attempt_delta = 0
            max_pending_bytes = 0
            marker = f"BACKPRESSURE_DONE_{uuid.uuid4().hex[:10]}"
            burst_command = "; ".join(
                f"yes | head -c {OUTPUT_BYTES}"
                for _ in range(OUTPUT_BURSTS)
            )
            client.send_surface(
                leader_panel,
                f"{burst_command}; printf '\n{marker}\n'\r",
            )
            deadline = time.time() + 60
            final = None
            while time.time() < deadline:
                current = _pane_status(client, leader_surface)
                if current is None:
                    raise termmeshError("leader relay disappeared during heavy output")
                final = current
                io = current.get("io") or {}
                max_attempt_delta = max(max_attempt_delta, int(io.get("reconnect_attempts") or 0) - int(io_before.get("reconnect_attempts") or 0))
                max_pending_bytes = max(
                    max_pending_bytes,
                    max(0, int(io.get("bytes_received") or 0) - int(io.get("bytes_enqueued") or 0)),
                )
                max_fd = max(max_fd, _fd_count(process["pid"]))
                if marker in client.read_terminal_text(leader_panel):
                    break
                time.sleep(POLL_INTERVAL_SECONDS)
            if final is None or marker not in client.read_terminal_text(leader_panel):
                raise termmeshError("heavy-output convergence marker did not arrive")
            time.sleep(1.0)
            final = _pane_status(client, leader_surface) or final
            io_after = final.get("io") or {}
            if int(io_after.get("bytes_received") or 0) <= int(io_before.get("bytes_received") or 0):
                raise termmeshError(f"relay received no output bytes: before={io_before!r} after={io_after!r}")
            if final.get("torn_down") or final.get("relay_liveness") == "ended":
                raise termmeshError(f"leader relay did not converge live: {final!r}")
            if max_attempt_delta > MAX_RECONNECT_ATTEMPTS:
                raise termmeshError(f"reconnect attempt bound exceeded: delta={max_attempt_delta} final={io_after!r}")
            if max_fd - fd_baseline > MAX_FD_GROWTH:
                raise termmeshError(f"GUI FD growth exceeded bound: baseline={fd_baseline} max={max_fd}")
            markers = _count_markers(log_path, log_offset)
            if markers["unexpected_eof"] > MAX_RECONNECT_ATTEMPTS:
                raise termmeshError(f"unexpected EOF storm exceeded bound: {markers!r}")
            before_telemetry = before.get("relay_telemetry") or {}
            after_telemetry = final.get("relay_telemetry") or {}
            boundary_observed = (
                markers["overflow_episodes"] > 0
                or markers["queue_drops"] > 0
                or int(io_after.get("bytes_dropped") or 0) > int(io_before.get("bytes_dropped") or 0)
                or int(io_after.get("resume_gate_buffered_bytes") or 0) > int(io_before.get("resume_gate_buffered_bytes") or 0)
                or max_pending_bytes > 0
                or int(after_telemetry.get("host_aggregate_dropped_chunks") or 0) > int(before_telemetry.get("host_aggregate_dropped_chunks") or 0)
            )
            boundary_observed = boundary_observed or gui_stress["queue_boundary_observed"]
            bounded_failure_observed = gui_stress["bounded_attachment_failure_observed"]
            if not boundary_observed and not bounded_failure_observed:
                raise termmeshError(
                    "heavy-output gate completed without resync or bounded attachment evidence: "
                    f"before={io_before!r} after={io_after!r} "
                    f"final={final!r} markers={markers!r} "
                    f"max_pending_bytes={max_pending_bytes} "
                    f"gui_stress={gui_stress!r}"
                )
            manifest_after = _manifest(client, host, project_id, leader_surface, members)
            if manifest_after is None:
                raise termmeshError("Project manifest or exact member identity was lost after heavy output")
            evidence.update({"before_io": io_before, "after_io": io_after, "final_relay": final, "log_markers": markers, "fd_baseline": fd_baseline, "fd_max": max_fd, "max_reconnect_attempt_delta": max_attempt_delta, "max_pending_bytes": max_pending_bytes, "output_bytes_per_burst": OUTPUT_BYTES, "output_bursts": OUTPUT_BURSTS, "queue_boundary_observed": boundary_observed, "bounded_convergence_observed": True})

            deletion = client.debug_project_delete(team_name)
            evidence["cleanup_receipt"]["requested"] = True
            deletion_id = str(deletion.get("operation_id") or "")
            if not deletion_id:
                raise termmeshError(f"Project cleanup returned no operation id: {deletion!r}")
            if _wait(lambda: client.debug_project_delete_status(deletion_id).get("state") == "succeeded", timeout_s=60) is None:
                raise termmeshError("Project cleanup did not complete")
            cleaned = _wait(lambda: not any(item.get("project_id") == project_id for item in client.debug_project_remote_presentations(host)) and not any(item.get("team_name") == team_name for item in client.team_list()), timeout_s=45) is not None
            if not cleaned:
                raise termmeshError("Project cleanup receipt completed but local state remains")
            evidence["cleanup_receipt"].update({"completed": True, "operation_id": deletion_id, "remaining_project": False, "remaining_team": False})
        finally:
            if state is not None and not cleaned:
                try:
                    client.debug_project_delete(state["team_name"])
                except Exception:
                    evidence["cleanup_receipt"]["fallback_error"] = True
    receipt = os.environ.get("TERMMESH_E2E_BACKPRESSURE_RECEIPT", "").strip()
    if receipt:
        evidence["cleanup_receipt"]["path"] = receipt
        Path(receipt).write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print("PASS: bounded heavy-output relay recovery and exact Project convergence " + json.dumps(evidence, sort_keys=True))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    return _dry_run() if args.dry_run else _run()


if __name__ == "__main__":
    raise SystemExit(main())
