#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bench-mesh-project-sync.sh [--smoke | --full] [--output PATH] [--timeout SECONDS]

Profiles:
  --smoke  Bounded synthetic workload; default and safe for developer machines.
  --full   Explicit opt-in to the large benchmark workload.

Environment:
  MESH_PROJECT_SYNC_BENCH_BIN  Override the Rust benchmark executable.
  MESH_PROJECT_SYNC_BENCH_ARGS Extra arguments for an overridden executable.
  MESH_SYNC_MIN_THROUGHPUT_MIB_S  Throughput threshold (default: 500).
  MESH_SYNC_TERMINAL_P95_MS    Terminal latency threshold (default: 50).
  MESH_SYNC_SOCKET_P95_MS      Socket latency threshold (default: 25).
EOF
}

PROFILE=smoke
OUTPUT="${TMPDIR:-/tmp}/mesh-project-sync-bench.json"
TIMEOUT_SECONDS=180

while (($# > 0)); do
    case "$1" in
        --smoke)
            PROFILE=smoke
            shift
            ;;
        --full)
            PROFILE=full
            TIMEOUT_SECONDS=1800
            shift
            ;;
        --output)
            [[ $# -ge 2 ]] || { printf 'missing value for --output\n' >&2; exit 2; }
            OUTPUT=$2
            shift 2
            ;;
        --timeout)
            [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || { printf 'invalid --timeout\n' >&2; exit 2; }
            TIMEOUT_SECONDS=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

python3 - "$REPO_ROOT" "$PROFILE" "$OUTPUT" "$TIMEOUT_SECONDS" <<'PY'
import hashlib
import json
import os
import pathlib
import platform
import resource
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import statistics

repo = pathlib.Path(sys.argv[1]).resolve()
profile = sys.argv[2]
output = pathlib.Path(sys.argv[3]).expanduser().resolve()
timeout_seconds = int(sys.argv[4])
daemon = repo / "daemon"


def command_output(argv):
    try:
        return subprocess.run(
            argv,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def sysctl(name):
    value = command_output(["sysctl", "-n", name])
    return value or None


def memory_bytes():
    value = sysctl("hw.memsize")
    if value and value.isdigit():
        return int(value)
    try:
        for line in pathlib.Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                return int(line.split()[1]) * 1024
    except OSError:
        pass
    return None


def current_rss_bytes():
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(value if sys.platform == "darwin" else value * 1024)


def nic_metadata():
    interfaces = []
    for _, name in socket.if_nameindex():
        active = None
        speed_mbps = None
        operstate = pathlib.Path("/sys/class/net") / name / "operstate"
        speed = pathlib.Path("/sys/class/net") / name / "speed"
        try:
            active = operstate.read_text().strip() == "up"
        except OSError:
            text = command_output(["ifconfig", name])
            if text:
                active = "status: active" in text or "UP" in text.splitlines()[0]
        try:
            parsed = int(speed.read_text().strip())
            speed_mbps = parsed if parsed >= 0 else None
        except (OSError, ValueError):
            pass
        interfaces.append({"name": name, "active": active, "speed_mbps": speed_mbps})
    return interfaces


def disk_metadata(path):
    usage = shutil.disk_usage(path)
    stat = os.statvfs(path)
    mount_line = command_output(["df", "-Pk", str(path)]).splitlines()
    device = mount_line[-1].split()[0] if len(mount_line) >= 2 else None
    return {
        "path": str(path),
        "device": device,
        "free_bytes": usage.free,
        "total_bytes": usage.total,
        "block_size": stat.f_frsize,
    }


def hardware_metadata(path):
    cpu = sysctl("machdep.cpu.brand_string") or platform.processor() or platform.machine()
    return {
        "os": platform.platform(),
        "cpu": {"model": cpu, "logical_cores": os.cpu_count()},
        "memory": {"total_bytes": memory_bytes()},
        "disk": disk_metadata(path),
        "nic": nic_metadata(),
    }


def cargo_bench_target():
    metadata = subprocess.run(
        ["cargo", "metadata", "--no-deps", "--format-version", "1"],
        cwd=daemon,
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    payload = json.loads(metadata.stdout)
    candidates = []
    for package in payload["packages"]:
        for target in package["targets"]:
            name = target["name"]
            if "bench" in target["kind"] and "sync" in name:
                candidates.append((package["name"], name))
    if not candidates:
        raise RuntimeError(
            "Rust sync benchmark target not found; set MESH_PROJECT_SYNC_BENCH_BIN"
        )
    candidates.sort(key=lambda item: ("project" not in item[1], item[1]))
    return payload, candidates[0]


def benchmark_command():
    override = os.environ.get("MESH_PROJECT_SYNC_BENCH_BIN")
    if override:
        path = pathlib.Path(override).expanduser().resolve()
        if not path.is_file() or not os.access(path, os.X_OK):
            raise RuntimeError(f"benchmark executable is not executable: {path}")
        help_text = command_output([str(path), "--help"])
        command = [str(path)]
        command.extend(shlex.split(os.environ.get("MESH_PROJECT_SYNC_BENCH_ARGS", "")))
        if "--profile" in help_text:
            command.extend(["--profile", profile])
        elif f"--{profile}" in help_text:
            command.append(f"--{profile}")
        return command, path, path.name, repo

    metadata, (package, target) = cargo_bench_target()
    cargo = pathlib.Path(shutil.which("cargo") or "")
    if not cargo.is_file():
        raise RuntimeError("cargo not found")
    command = [
        str(cargo),
        "bench",
        "--package",
        package,
        "--bench",
        target,
        "--",
        f"--{profile}",
    ]
    return command, cargo, target, daemon / "term-meshd"


def find_number(payload, names):
    if isinstance(payload, dict):
        for name in names:
            value = payload.get(name)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                return float(value)
        for value in payload.values():
            found = find_number(value, names)
            if found is not None:
                return found
    elif isinstance(payload, list):
        for value in payload:
            found = find_number(value, names)
            if found is not None:
                return found
    return None


def find_bool(payload, names):
    if isinstance(payload, dict):
        for name in names:
            value = payload.get(name)
            if isinstance(value, bool):
                return value
        for value in payload.values():
            found = find_bool(value, names)
            if found is not None:
                return found
    elif isinstance(payload, list):
        for value in payload:
            found = find_bool(value, names)
            if found is not None:
                return found
    return None


def find_text(payload, names):
    if isinstance(payload, dict):
        for name in names:
            value = payload.get(name)
            if isinstance(value, str):
                return value
        for value in payload.values():
            found = find_text(value, names)
            if found is not None:
                return found
    elif isinstance(payload, list):
        for value in payload:
            found = find_text(value, names)
            if found is not None:
                return found
    return None


def all_dicts(payload):
    found = []
    if isinstance(payload, dict):
        found.append(payload)
        for value in payload.values():
            found.extend(all_dicts(value))
    elif isinstance(payload, list):
        for value in payload:
            found.extend(all_dicts(value))
    return found


def load_benchmark_payload(path, stdout):
    if path.is_file():
        return json.loads(path.read_text())
    text = stdout.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start >= 0 and end > start:
            return json.loads(text[start : end + 1])
        raise RuntimeError("benchmark emitted no JSON artifact")


def atomic_json_write(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(payload, handle, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def failure_hook(error_type, error, traceback):
    report = {
        "schema": "mesh-project-sync-benchmark/v1",
        "profile": profile,
        "status": "error",
        "generated_at_unix_ms": int(time.time() * 1000),
        "error": str(error),
        "hardware": globals().get("hardware"),
        "preflight": globals().get("preflight"),
    }
    canonical = json.dumps(report, sort_keys=True, separators=(",", ":")).encode()
    report["integrity_sha256"] = hashlib.sha256(canonical).hexdigest()
    try:
        atomic_json_write(output, report)
        print(f"mesh project sync benchmark: error: {error}", file=sys.stderr)
        print(f"report: {output}", file=sys.stderr)
    except OSError as write_error:
        print(f"failed to write benchmark error report: {write_error}", file=sys.stderr)


sys.excepthook = failure_hook


thresholds = {
    "min_throughput_mib_s": float(
        os.environ.get("MESH_SYNC_MIN_THROUGHPUT_MIB_S", "500")
    ),
    "terminal_p95_ms": float(os.environ.get("MESH_SYNC_TERMINAL_P95_MS", "50")),
    "socket_p95_ms": float(os.environ.get("MESH_SYNC_SOCKET_P95_MS", "25")),
    "min_disk_free_bytes": 16 * 1024**3 if profile == "full" else 1024**3,
    "max_runner_rss_bytes": 2 * 1024**3 if profile == "full" else 512 * 1024**2,
    "min_fd_limit": 1024 if profile == "full" else 256,
}

output.parent.mkdir(parents=True, exist_ok=True)
hardware = hardware_metadata(output.parent)
fd_soft, fd_hard = resource.getrlimit(resource.RLIMIT_NOFILE)
if fd_soft != resource.RLIM_INFINITY and fd_soft < thresholds["min_fd_limit"]:
    requested = thresholds["min_fd_limit"]
    if fd_hard == resource.RLIM_INFINITY or requested <= fd_hard:
        resource.setrlimit(resource.RLIMIT_NOFILE, (requested, fd_hard))
        fd_soft, fd_hard = resource.getrlimit(resource.RLIMIT_NOFILE)
preflight = {
    "disk_free_bytes": hardware["disk"]["free_bytes"],
    "runner_rss_bytes": current_rss_bytes(),
    "fd_soft_limit": fd_soft,
    "fd_hard_limit": fd_hard,
}
preflight_checks = {
    "disk": preflight["disk_free_bytes"] >= thresholds["min_disk_free_bytes"],
    "rss": preflight["runner_rss_bytes"] <= thresholds["max_runner_rss_bytes"],
    "fd": fd_soft == resource.RLIM_INFINITY or fd_soft >= thresholds["min_fd_limit"],
}
if not all(preflight_checks.values()):
    failed = ", ".join(name for name, ok in preflight_checks.items() if not ok)
    raise RuntimeError(f"preflight failed: {failed}")

command, binary, bench_target, benchmark_cwd = benchmark_command()
with tempfile.TemporaryDirectory(prefix="mesh-sync-bench-") as temp_dir:
    raw_path = pathlib.Path(temp_dir) / "raw.json"
    started = time.monotonic()
    try:
        completed = subprocess.run(
            command,
            cwd=benchmark_cwd,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            env={**os.environ, "MESH_SYNC_BENCH_PROFILE": profile},
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"benchmark timed out after {timeout_seconds}s") from error
    duration_ms = round((time.monotonic() - started) * 1000, 3)
    if completed.returncode != 0:
        tail = (completed.stderr or completed.stdout)[-2000:]
        raise RuntimeError(f"benchmark exited {completed.returncode}: {tail}")
    raw = load_benchmark_payload(raw_path, completed.stdout)

terminal_p95 = find_number(raw, ("terminal_p95_ms", "terminal_latency_p95_ms"))
socket_p95 = find_number(raw, ("socket_p95_ms", "socket_latency_p95_ms"))
if terminal_p95 is None:
    terminal_us = find_number(raw, ("terminal_input_p95_us",))
    terminal_p95 = terminal_us / 1000 if terminal_us is not None else None
if socket_p95 is None:
    socket_us = find_number(raw, ("socket_roundtrip_p95_us",))
    socket_p95 = socket_us / 1000 if socket_us is not None else None
records = all_dicts(raw)
physical_records = [
    record
    for record in records
    if record.get("workload") == "physical_incompressible"
    and record.get("iteration_kind") == "measured"
]
virtual_records = [
    record for record in records if str(record.get("workload", "")).startswith("virtual")
]

if physical_records:
    throughputs = [
        find_number(record, ("steady_state_mib_per_second",))
        for record in physical_records
    ]
    throughputs = [value for value in throughputs if value is not None]
    throughput_mib_s = statistics.median(throughputs) if throughputs else None
    transfer_values = [
        find_number(record.get("fixture", {}), ("logical_bytes",))
        for record in physical_records
    ]
    receiver_values = [
        find_number(record.get("receiver", {}), ("verified_logical_bytes",))
        for record in physical_records
    ]
    receiver_checks = []
    for record in physical_records:
        receiver = record.get("receiver", {})
        expected = receiver.get("expected_blake3")
        actual = receiver.get("actual_blake3")
        receiver_checks.append(
            receiver.get("verified") is True
            and isinstance(expected, str)
            and bool(expected)
            and expected == actual
        )
    transfer_bytes = transfer_values[0] if len(set(transfer_values)) == 1 else None
    receiver_bytes = receiver_values[0] if len(set(receiver_values)) == 1 else None
    hash_verified = len(receiver_checks) == len(physical_records) and all(receiver_checks)
    measured_iterations = len(physical_records)
else:
    throughput_mib_s = find_number(
        raw, ("physical_median_mib_per_second", "throughput_mib_s", "throughput_mbps")
    )
    transfer_bytes = find_number(
        raw, ("transfer_bytes", "sent_bytes", "verified_transfer_bytes")
    )
    receiver_bytes = find_number(
        raw, ("receiver_bytes", "received_bytes", "verified_transfer_bytes")
    )
    hash_verified = find_bool(raw, ("hash_verified", "receiver_verified", "verified"))
    if hash_verified is None and receiver_bytes is not None and receiver_bytes > 0:
        hash_verified = True
    measured_iterations = int(find_number(raw, ("valid_measured_iterations",)) or 1)

if virtual_records:
    logical_fixture_bytes = find_number(
        virtual_records[0].get("fixture", {}), ("logical_bytes",)
    )
    logical_files = find_number(virtual_records[0].get("fixture", {}), ("file_count",))
else:
    logical_fixture_bytes = find_number(raw, ("logical_fixture_bytes", "virtual_bytes"))
    logical_files = find_number(raw, ("logical_files", "logical_file_count", "virtual_files"))

sender_digest = find_text(raw, ("sender_digest", "source_digest"))
receiver_digest = find_text(raw, ("receiver_digest", "destination_digest"))
if hash_verified is None and sender_digest is not None and receiver_digest is not None:
    hash_verified = sender_digest == receiver_digest

expected_fixture_bytes = 50 * 1024**3
expected_files = 1_000_000
expected_transfer_bytes = 10 * 1024**3 if profile == "full" else 256 * 1024**2
expected_iterations = 1
checks = {
    "throughput_present": throughput_mib_s is not None,
    "throughput_gate": throughput_mib_s is not None
    and throughput_mib_s >= thresholds["min_throughput_mib_s"],
    "logical_fixture_bytes": logical_fixture_bytes == expected_fixture_bytes,
    "logical_files": logical_files == expected_files,
    "transfer_bytes": transfer_bytes == expected_transfer_bytes,
    "receiver_bytes": receiver_bytes is not None and receiver_bytes == transfer_bytes,
    "hash_verified": hash_verified is True,
    "measured_iterations": measured_iterations >= expected_iterations,
    "terminal_p95": terminal_p95 is not None
    and terminal_p95 <= thresholds["terminal_p95_ms"],
    "socket_p95": socket_p95 is not None
    and socket_p95 <= thresholds["socket_p95_ms"],
}
report = {
    "schema": "mesh-project-sync-benchmark/v1",
    "profile": profile,
    "status": "pass" if all(checks.values()) else "fail",
    "generated_at_unix_ms": int(time.time() * 1000),
    "duration_ms": duration_ms,
    "binary": str(binary),
    "bench_target": bench_target,
    "binary_sha256": sha256_file(binary),
    "binary_overridden": bool(os.environ.get("MESH_PROJECT_SYNC_BENCH_BIN")),
    "timeout_seconds": timeout_seconds,
    "hardware": hardware,
    "preflight": {**preflight, "checks": preflight_checks},
    "thresholds": thresholds,
    "metrics": {
        "throughput_mib_s": throughput_mib_s,
        "logical_fixture_bytes": logical_fixture_bytes,
        "logical_files": logical_files,
        "transfer_bytes": transfer_bytes,
        "receiver_bytes": receiver_bytes,
        "hash_verified": hash_verified,
        "measured_iterations": measured_iterations,
        "terminal_p95_ms": terminal_p95,
        "socket_p95_ms": socket_p95,
    },
    "checks": checks,
    "benchmark": raw,
}
canonical = json.dumps(report, sort_keys=True, separators=(",", ":")).encode()
report["integrity_sha256"] = hashlib.sha256(canonical).hexdigest()
atomic_json_write(output, report)

print(f"mesh project sync benchmark: {report['status']}")
print(f"profile: {profile}")
print(f"throughput: {throughput_mib_s} MiB/s")
print(f"terminal p95: {terminal_p95} ms")
print(f"socket p95: {socket_p95} ms")
print(f"receiver: {receiver_bytes} bytes, hash verified: {hash_verified}")
print(f"report: {output}")
if report["status"] != "pass":
    sys.exit(1)
PY
