#!/usr/bin/env python3
"""Capture peer relay process, socket, and log evidence without app RPC."""

import argparse
import json
import signal
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

EVENT_MARKERS = {
    "overflow_episodes": "overflow-episode",
    "queue_drops": "queue-drop",
    "queue_watermarks": "queue-watermark",
    "queue_observations": "queue-observation",
    "attachment_aborts": "attachment-abort",
    "snapshot_heals": "snapshot-heal",
    "unexpected_eof": "unexpectedEof",
    "transport_closes": "transport-close",
    "write_errors": "write-error",
    "pty_write_errors": "pty-write-error",
    "relay_gaps": "peer.relay.gap",
}
EVENT_FILTER = tuple(EVENT_MARKERS.values()) + ("peer.relay.", "resume-gate")
_stop_requested = False


def marker_counts(lines: List[str]) -> Dict[str, int]:
    return {name: sum(line.count(marker) for line in lines) for name, marker in EVENT_MARKERS.items()}


def _run(command: List[str], timeout: float = 3.0) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return subprocess.CompletedProcess(command, 1, "", str(exc))


def _pid_from_file(path: str) -> Optional[int]:
    try:
        return int(Path(path).read_text().strip())
    except (OSError, ValueError):
        return None


def _process_table() -> Dict[int, Dict[str, Any]]:
    result = _run(["ps", "-axo", "pid=,ppid=,state=,etime=,pcpu=,rss=,command="])
    rows: Dict[int, Dict[str, Any]] = {}
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 6)
        if len(fields) < 7:
            continue
        try:
            pid, ppid = int(fields[0]), int(fields[1])
        except ValueError:
            continue
        command = fields[6]
        rows[pid] = {
            "pid": pid,
            "ppid": ppid,
            "state": fields[2],
            "elapsed": fields[3],
            "cpu_percent": fields[4],
            "rss_kb": fields[5],
            "name": Path(command.split(None, 1)[0]).name if command else "",
            "is_peer_relay": "term-mesh-peer-relay" in command,
        }
    return rows


def _descendants(rows: Dict[int, Dict[str, Any]], roots: List[int]) -> List[int]:
    parents: Dict[int, List[int]] = {}
    for pid, row in rows.items():
        parents.setdefault(int(row["ppid"]), []).append(pid)
    found = set(roots)
    pending = list(roots)
    while pending:
        for child in parents.get(pending.pop(), []):
            if child not in found:
                found.add(child)
                pending.append(child)
    return sorted(found)


def _socket_snapshot(pids: List[int]) -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []
    for pid in pids:
        result = _run(["lsof", "-nP", "-a", "-p", str(pid), "-U", "-Fpcfn"])
        process = ""
        command = ""
        fd = ""
        for line in result.stdout.splitlines():
            if line.startswith("p"):
                process = line[1:]
            elif line.startswith("c"):
                command = line[1:]
            elif line.startswith("f"):
                fd = line[1:]
            elif line.startswith("n") and line[1:]:
                name = line[1:]
                if "peer" in name.lower() or "term-mesh" in name.lower() or name.endswith(".sock"):
                    rows.append({"pid": process, "command": command, "fd": fd, "name": name})
    return rows


def _debug_log_path(pid: Optional[int]) -> Optional[str]:
    if pid is None:
        return None
    result = _run(["lsof", "-nP", "-a", "-p", str(pid), "-Fn"])
    for line in result.stdout.splitlines():
        if not line.startswith("n"):
            continue
        path = line[1:]
        if path.endswith(".log") and "debug" in path.lower():
            return path
    return None


def _read_log(path: Optional[str], offset: int) -> Tuple[int, List[str]]:
    if not path:
        return offset, []
    try:
        with Path(path).open("rb") as source:
            size = source.seek(0, 2)
            if size < offset:
                offset = 0
            source.seek(offset)
            data = source.read(1024 * 1024)
            next_offset = source.tell()
    except OSError:
        return offset, []
    lines = data.decode("utf-8", "replace").splitlines()
    events = [line[:600] for line in lines if any(marker in line for marker in EVENT_FILTER)]
    return next_offset, events


def _write_row(output, row: Dict[str, Any]) -> None:
    output.write(json.dumps(row, sort_keys=True) + "\n")
    output.flush()


def watch(args: argparse.Namespace) -> int:
    global _stop_requested

    def request_stop(_signum, _frame):
        global _stop_requested
        _stop_requested = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    app_pid = _pid_from_file(args.app_pid_file)
    peer_offset = args.peer_log_offset
    debug_path = _debug_log_path(app_pid)
    debug_offset = 0
    if debug_path:
        try:
            debug_offset = Path(debug_path).stat().st_size
        except OSError:
            debug_offset = 0
    counters: Counter = Counter()
    sample_count = 0
    socket_names = set()
    last_socket_pids: List[int] = []
    last_socket_sample = 0.0
    app_states = Counter()
    relay_states = Counter()
    started = time.monotonic()

    with output_path.open("x", encoding="utf-8") as output:
        _write_row(output, {
            "kind": "started",
            "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "app_pid": app_pid,
            "peer_log": args.peer_log,
        })
        while not _stop_requested and time.monotonic() - started < args.duration:
            rows = _process_table()
            roots = [pid for pid in [app_pid] if pid is not None]
            related = _descendants(rows, roots)
            relay_pids = [pid for pid in related if rows.get(pid, {}).get("is_peer_relay")]
            target_pids = sorted(set(roots + relay_pids))
            now = time.monotonic()
            if target_pids != last_socket_pids or now - last_socket_sample >= args.socket_interval:
                sockets = _socket_snapshot(target_pids)
                last_socket_pids = target_pids
                last_socket_sample = now
            for item in sockets:
                socket_names.add(item["name"])

            app_row = rows.get(app_pid) if app_pid is not None else None
            output_producers = [
                rows[pid] for pid in related
                if rows.get(pid, {}).get("name") in {"yes", "head"}
            ]
            if app_row:
                app_states[app_row["state"]] += 1
            for pid in relay_pids:
                state = str(rows[pid]["state"])
                relay_states[state] += 1

            peer_offset, peer_events = _read_log(args.peer_log, peer_offset)
            debug_offset, debug_events = _read_log(debug_path, debug_offset)
            event_rows = ([{"source": "peer_server", "line": line} for line in peer_events]
                          + [{"source": "debug", "line": line} for line in debug_events])
            event_lines = [row["line"] for row in event_rows]
            counters.update(marker_counts(event_lines))
            sample_count += 1
            _write_row(output, {
                "kind": "sample",
                "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "app": app_row,
                "peer_relays": [rows[pid] for pid in relay_pids],
                "output_producers": output_producers,
                "sockets": sockets,
                "log_events": event_rows,
            })
            time.sleep(args.interval)

        _write_row(output, {
            "kind": "summary",
            "sample_count": sample_count,
            "markers": dict(counters),
            "socket_names": sorted(socket_names),
            "app_states": dict(app_states),
            "peer_relay_states": dict(relay_states),
            "debug_log": debug_path,
        })
    return 0


def dry_run() -> int:
    sample = [
        "overflow-episode surface=abc",
        "queue-drop chunks=2",
        "queue-watermark surface=abc percent=25 pending_bytes=262144",
        "queue-observation surface=abc peak_bytes=262144",
        "snapshot-heal surface=abc",
        "peer.relay.gap bytes=64",
    ]
    actual = marker_counts(sample)
    expected = {
        "overflow_episodes": 1,
        "queue_drops": 1,
        "queue_watermarks": 1,
        "queue_observations": 1,
        "attachment_aborts": 0,
        "snapshot_heals": 1,
        "unexpected_eof": 0,
        "transport_closes": 0,
        "write_errors": 0,
        "pty_write_errors": 0,
        "relay_gaps": 1,
    }
    if actual != expected:
        raise RuntimeError(f"watcher marker contract mismatch: expected={expected!r} actual={actual!r}")
    print("PASS: peer stall watcher marker contract")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--output")
    parser.add_argument("--app-pid-file")
    parser.add_argument("--peer-log", default="/tmp/term-mesh-peer-server.log")
    parser.add_argument("--peer-log-offset", type=int, default=0)
    parser.add_argument("--duration", type=float, default=600.0)
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--socket-interval", type=float, default=10.0)
    args = parser.parse_args()
    if args.dry_run:
        return dry_run()
    if not args.output or not args.app_pid_file:
        parser.error("--output and --app-pid-file are required")
    return watch(args)


if __name__ == "__main__":
    raise SystemExit(main())
