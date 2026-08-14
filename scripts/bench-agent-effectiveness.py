#!/usr/bin/env python3
"""Measure validated development throughput for one session vs a 3-worker team.

The benchmark replays resolved term-mesh work from history-free snapshots.  The
solution commit is used only by the controller to provide hidden acceptance
tests; agents never receive its SHA or objects.  See
docs/multi-agent-effectiveness-benchmark.md for the experiment contract.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import random
import re
import selectors
import shlex
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Iterator, Optional, TextIO

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RESULTS = Path.home() / ".term-mesh" / "benchmarks" / "effectiveness"
DEFAULT_SEED = 20260814
DEFAULT_TIMEOUT = 45 * 60
DEFAULT_INFRA_RETRIES = 1
CONDITIONS = ("single", "multi")
TOKEN_KEYS = (
    "input_tokens", "output_tokens", "reasoning_output_tokens",
    "cache_read_input_tokens", "cache_creation_input_tokens",
)
MODEL_PRICING_PER_MTOK = {
    # Controller estimates only; provider-reported leader cost is authoritative.
    "haiku": {"input": 0.80, "output": 4.0, "cache_read": 0.08, "cache_write": 1.0},
    "sonnet": {"input": 3.0, "output": 15.0, "cache_read": 0.30, "cache_write": 3.75},
    "opus": {"input": 15.0, "output": 75.0, "cache_read": 1.50, "cache_write": 18.75},
}


@dataclass(frozen=True)
class Fixture:
    name: str
    parallelism: str
    solution: str
    prompt: str
    oracle_files: tuple[str, ...]
    acceptance: str


FIXTURES: dict[str, Fixture] = {
    "homebrew-smoke": Fixture(
        name="homebrew-smoke", parallelism="low", solution="8803af77",
        prompt=(
            "Homebrew release smoke test의 기본 경로가 로컬 term-mesh 앱이나 Caskroom을 "
            "건드리지 않게 수정하라. 기본 경로는 DMG version, tap SHA, brew fetch를 "
            "검증하고 실제 uninstall/install은 SMOKE_TEST=full에서만 실행해야 한다. "
            "생성 cask의 preflight pkill은 교체할 app bundle이 있을 때만 실행되어야 한다. "
            ".claude/commands/release.md도 안전한 기본 경로와 full opt-in을 설명하게 갱신하라."
        ),
        oracle_files=(), acceptance="homebrew",
    ),
    "ghostty-kit-guard": Fixture(
        name="ghostty-kit-guard", parallelism="medium", solution="9b7745b1",
        prompt=(
            "GhosttyKit header ABI가 같더라도 framework implementation이 parent가 pin한 "
            "ghostty commit보다 오래될 수 있다. parent pin, submodule HEAD, framework "
            "stamp, cache symlink SHA, static archive, header ABI의 일치 여부를 검사하는 "
            "공통 guard를 만들고 setup, reload, Xcode build, release publish 경계에 연결하라."
        ),
        oracle_files=("scripts/test-ghostty-kit-guard.sh",), acceptance="ghostty",
    ),
    "split-divider-color": Fixture(
        name="split-divider-color", parallelism="high", solution="4e954beb",
        prompt=(
            "사용자가 split divider color를 설정하고 reset할 수 있게 하라. 설정은 Ghostty "
            "config와 Bonsplit/portal runtime에 즉시 반영되어야 한다. opaque 사용자 색은 "
            "terminal surface가 divider를 가리지 않아도 overlay로 보여야 하고 기존 "
            "translucent separator의 occlusion 정책은 유지하라. 관련 unit test를 추가하라."
        ),
        oracle_files=(
            "termMeshTests/GhosttyConfigTests.swift",
            "termMeshTests/GhosttyTerminalViewComposingTests.swift",
            "termMeshTests/TerminalOverrideIsolationTests.swift",
        ),
        acceptance="divider",
    ),
}


@dataclass(frozen=True)
class RunSpec:
    fixture: str
    trial: int
    condition: str
    order: int


@dataclass
class RunResult:
    run_id: str
    fixture: str
    parallelism: str
    trial: int
    condition: str
    order: int
    started_at: str
    finished_at: Optional[str] = None
    status: str = "failed"
    acceptance_passed: bool = False
    infra_invalid: bool = False
    timed_out: bool = False
    failure_reason: Optional[str] = None
    total_wall_ms: Optional[int] = None
    active_task_ms: Optional[int] = None
    team_init_ms: int = 0
    time_to_first_action_ms: Optional[int] = None
    acceptance_ms: int = 0
    correction_count: int = 0
    leader_turns: int = 0
    worker_tasks: int = 0
    worker_active_critical_path_ms: Optional[int] = None
    worker_utilization: Optional[float] = None
    rework_count: int = 0
    tokens: dict[str, int] = field(default_factory=dict)
    token_precision: str = "actual"
    cost_usd: Optional[float] = None
    cost_precision: str = "unavailable"
    changed_files: int = 0
    paths: dict[str, str] = field(default_factory=dict)


class BenchmarkTerminated(RuntimeError):
    """Turn SIGTERM into normal stack unwinding so teams and scratch are cleaned."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def run_command(
    args: Iterable[str], *, cwd: Path = ROOT, timeout: Optional[float] = None,
    env: Optional[dict[str, str]] = None, input_text: Optional[str] = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(args), cwd=cwd, text=True, input=input_text, capture_output=True,
        timeout=timeout, env=env, check=False,
    )


def git(*args: str, cwd: Path = ROOT, timeout: int = 120) -> str:
    result = run_command(("git", *args), cwd=cwd, timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout.strip()


def validate_fixture_metadata() -> list[dict[str, Any]]:
    rows = []
    for fixture in FIXTURES.values():
        solution = git("rev-parse", f"{fixture.solution}^{{commit}}")
        parent = git("rev-parse", f"{fixture.solution}^")
        for path in fixture.oracle_files:
            git("cat-file", "-e", f"{fixture.solution}:{path}")
        rows.append({
            "fixture": fixture.name, "solution": solution, "base": parent,
            "oracle_files": list(fixture.oracle_files),
        })
    return rows


def command_version(*command: str) -> str:
    result = run_command(command, timeout=15)
    output = (result.stdout or result.stderr).strip().splitlines()
    return output[0] if result.returncode == 0 and output else "unavailable"


def build_matrix(
    fixtures: Iterable[str], trials: int, seed: int, conditions: Iterable[str] = CONDITIONS,
) -> list[RunSpec]:
    """Build paired, non-concurrent runs with counterbalanced order."""
    rng = random.Random(seed)
    selected_conditions = tuple(conditions)
    specs: list[RunSpec] = []
    for fixture in fixtures:
        for trial in range(1, trials + 1):
            if trial == 1:
                order = CONDITIONS
            elif trial == 2:
                order = tuple(reversed(CONDITIONS))
            else:
                order = CONDITIONS if rng.random() < 0.5 else tuple(reversed(CONDITIONS))
            specs.extend(
                RunSpec(fixture, trial, condition, index)
                for index, condition in enumerate(order, 1)
                if condition in selected_conditions
            )
    return specs


def command_fingerprint(command: list[str]) -> str:
    return hashlib.sha256("\0".join(command).encode()).hexdigest()[:16]


def create_snapshot(fixture: Fixture, destination: Path, *, prepare: bool = True) -> None:
    """Create a one-commit repository that cannot resolve the solution SHA."""
    destination.mkdir(parents=True, exist_ok=False)
    archive = destination.parent / f"{destination.name}.tar"
    base = git("rev-parse", f"{fixture.solution}^")
    ghostty_sha = git("rev-parse", f"{base}:ghostty")
    exported = run_command(("git", "archive", "--format=tar", f"--output={archive}", base))
    if exported.returncode != 0:
        raise RuntimeError(f"fixture archive failed: {exported.stderr.strip()}")
    extracted = run_command(("tar", "-xf", str(archive), "-C", str(destination)))
    archive.unlink(missing_ok=True)
    if extracted.returncode != 0:
        raise RuntimeError(f"fixture extract failed: {extracted.stderr.strip()}")
    commands = (
        ("git", "init", "-b", "benchmark"),
        ("git", "config", "user.name", "term-mesh benchmark"),
        ("git", "config", "user.email", "benchmark@localhost"),
        ("git", "add", "-A"),
        ("git", "update-index", "--add", "--cacheinfo", f"160000,{ghostty_sha},ghostty"),
        ("git", "commit", "-m", "benchmark fixture snapshot"),
        ("git", "config", "submodule.ghostty.url", str(ROOT / "ghostty")),
    )
    for command in commands:
        result = run_command(command, cwd=destination, timeout=180)
        if result.returncode != 0:
            raise RuntimeError(f"snapshot init failed: {shlex.join(command)}: {result.stderr.strip()}")
    submodule = run_command(
        ("git", "-c", "protocol.file.allow=always", "submodule", "update", "--init", "ghostty"),
        cwd=destination, timeout=10 * 60,
    )
    if submodule.returncode != 0:
        raise RuntimeError(f"snapshot submodule failed: {submodule.stderr.strip()[-1200:]}")
    if prepare:
        setup = run_command(("bash", "scripts/setup.sh"), cwd=destination, timeout=30 * 60)
        if setup.returncode != 0:
            raise RuntimeError(f"snapshot setup failed: {(setup.stderr or setup.stdout)[-1600:]}")
    if git("status", "--porcelain", "--untracked-files=no", cwd=destination):
        raise RuntimeError("snapshot preparation modified tracked files")
    hidden = run_command(("git", "cat-file", "-e", f"{fixture.solution}^{{commit}}"), cwd=destination)
    if hidden.returncode == 0:
        raise RuntimeError("history isolation failed: solution object is visible")


@contextlib.contextmanager
def oracle_overlay(fixture: Fixture, checkout: Path) -> Iterator[None]:
    backups: dict[str, tuple[Optional[bytes], Optional[int]]] = {}
    try:
        for relative in fixture.oracle_files:
            target = checkout / relative
            backups[relative] = (
                target.read_bytes() if target.exists() else None,
                target.stat().st_mode if target.exists() else None,
            )
            target.parent.mkdir(parents=True, exist_ok=True)
            blob = subprocess.run(
                ("git", "show", f"{fixture.solution}:{relative}"), cwd=ROOT,
                capture_output=True, check=True,
            ).stdout
            target.write_bytes(blob)
            mode = git("ls-tree", fixture.solution, relative).split()[0]
            if mode == "100755":
                target.chmod(0o755)
        yield
    finally:
        for relative, (content, mode) in backups.items():
            target = checkout / relative
            if content is None:
                target.unlink(missing_ok=True)
            else:
                target.write_bytes(content)
                if mode is not None:
                    target.chmod(mode)


def shell_full_only_lines(text: str) -> set[int]:
    """Return lines proven to execute only when SMOKE_TEST is ``full``.

    This is deliberately a small structural reader, not a shell parser. It
    follows nested if/elif/else/fi clauses and recognizes either polarity of
    the SMOKE_TEST/full comparison. That is enough to distinguish destructive
    commands from safe checks without requiring one particular branch layout.
    """
    full_only: set[int] = set()
    stack: list[Optional[bool]] = []
    comparison = re.compile(
        r"SMOKE_TEST[^\n]*(?P<operator>==|!=)[^\n]*[\"']full[\"']"
        r"|[\"']full[\"'][^\n]*(?P<reverse>==|!=)[^\n]*SMOKE_TEST"
    )

    def clause_value(line: str) -> Optional[bool]:
        match = comparison.search(line)
        if not match:
            return None
        return (match.group("operator") or match.group("reverse")) == "=="

    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if re.match(r"^if\b", line):
            stack.append(clause_value(line))
        elif re.match(r"^elif\b", line) and stack:
            stack[-1] = clause_value(line)
        elif re.match(r"^else(?:\s|;|$)", line) and stack:
            if stack[-1] is not None:
                stack[-1] = not stack[-1]
        if any(value is True for value in stack):
            full_only.add(number)
        if re.match(r"^fi(?:\s|;|$)", line) and stack:
            stack.pop()
    return full_only


def homebrew_acceptance(checkout: Path) -> tuple[bool, str]:
    path = checkout / "scripts/update-homebrew-cask.sh"
    text = path.read_text()
    errors: list[str] = []
    smoke = text.find("# Post-publish smoke test")
    smoke_text = text[smoke:] if smoke >= 0 else text
    full_lines = shell_full_only_lines(smoke_text)
    if smoke < 0 or not full_lines:
        errors.append("SMOKE_TEST=full opt-in block is missing")
    executable_install = re.compile(r"^\s*(?:if\s+!\s+)?brew\s+(?:uninstall|install)\b", re.MULTILINE)
    for match in executable_install.finditer(smoke_text):
        line = smoke_text.count("\n", 0, match.start()) + 1
        if line not in full_lines:
            errors.append("default smoke path invokes brew install/uninstall")
            break
    for needle, label in (("hdiutil attach", "DMG version"), ("TAP_SHA=", "tap SHA"), ("brew fetch --cask", "brew fetch")):
        safe_occurrence = any(
            number not in full_lines and needle in line and not line.lstrip().startswith("#")
            for number, line in enumerate(smoke_text.splitlines(), 1)
        )
        if not safe_occurrence:
            errors.append(f"default smoke path does not verify {label}")
    preflight = re.search(
        r"preflight do(?P<body>.*?)(?:^\s*postflight do|^\s*uninstall\b)",
        text, re.MULTILINE | re.DOTALL,
    )
    guard_expression = (
        r"(?:File\.(?:exist|directory)\?\([^\n]*term-mesh\.app[^\n]*\)"
        r"|\([^\n]*appdir[^\n]*/[^\n]*term-mesh\.app[^\n]*\)\.(?:exist|directory)\?)"
    )
    guarded_pkill = preflight and re.search(
        rf"if\s+{guard_expression}(?:(?!^\s*end\b).)*?/usr/bin/pkill",
        preflight.group("body"), re.MULTILINE | re.DOTALL,
    )
    if not guarded_pkill:
        errors.append("generated cask preflight does not guard pkill with bundle existence")
    release_doc = checkout / ".claude/commands/release.md"
    documentation = release_doc.read_text() if release_doc.exists() else ""
    safe_default = re.search(
        r"(?:never installs? by default|safe\s+default[\s\S]{0,320}(?:never|does not|read.only|fetch)|"
        r"default[\s\S]{0,320}(?:safe|artifact|does not|never|read.only|fetch))",
        documentation, re.IGNORECASE,
    )
    full_opt_in = "SMOKE_TEST=full" in documentation and re.search(
        r"SMOKE_TEST=full[^\n]{0,200}(?:install|replace|quit|test machine)",
        documentation, re.IGNORECASE,
    )
    if not safe_default or not full_opt_in:
        errors.append("release documentation does not explain safe default and full opt-in")
    return not errors, "; ".join(errors) if errors else "homebrew hidden checks passed"


def run_logged(
    command: tuple[str, ...], *, checkout: Path, log: TextIO, timeout: float,
    env: Optional[dict[str, str]] = None,
) -> tuple[bool, str]:
    log.write(f"\n$ {shlex.join(command)}\n")
    log.flush()
    try:
        result = run_command(command, cwd=checkout, timeout=max(1, timeout), env=env)
    except subprocess.TimeoutExpired:
        return False, f"acceptance timeout: {shlex.join(command)}"
    log.write(redact_text(result.stdout, checkout))
    log.write(redact_text(result.stderr, checkout))
    log.flush()
    if result.returncode != 0:
        tail = (result.stdout + result.stderr)[-1200:].replace("\x00", "")
        return False, f"{shlex.join(command)} failed ({result.returncode}): {tail}"
    return True, "passed"


def run_divider_acceptance(
    checkout: Path, log: TextIO, timeout: float, xcode_host: str, run_id: str,
) -> tuple[bool, str]:
    tests = (
        "termMeshTests/WorkspaceChromeThemeTests/testResolvedChromeColorsUsesExplicitSplitDividerColor",
        "termMeshTests/GhosttyTerminalViewComposingTests/testDividerOverlayAlwaysRendersOpaqueUserColor",
        "termMeshTests/GhosttyTerminalViewComposingTests/testDividerOverlayKeepsDefaultSeparatorOcclusionPolicy",
        "termMeshTests/TerminalOverrideIsolationTests/test_configLines_setSplitDividerColorIsWritten",
    )
    command = [
        "xcodebuild", "-project", "GhosttyTabs.xcodeproj", "-scheme", "term-mesh-unit",
        "-configuration", "Debug", "-destination", "platform=macOS",
    ]
    for test in tests:
        command.extend(("-only-testing:" + test,))
    command.append("test")
    if xcode_host == "local":
        generated = run_command(("bash", "scripts/generate-build-info.sh"), cwd=checkout, timeout=30)
        if generated.returncode != 0:
            return False, f"BuildInfo generation failed: {generated.stderr.strip()}"
        ok, reason = run_logged(tuple(command), checkout=checkout, log=log, timeout=timeout)
        if not ok:
            return ok, reason
        return run_logged(
            ("xcodebuild", "-project", "GhosttyTabs.xcodeproj", "-scheme", "term-mesh",
             "-configuration", "Debug", "-destination", "platform=macOS", "build"),
            checkout=checkout, log=log, timeout=timeout,
        )
    remote = f"/tmp/term-mesh-effectiveness-{re.sub(r'[^A-Za-z0-9_.-]', '-', run_id)}"
    made = run_command(("ssh", xcode_host, "mkdir", "-p", remote), timeout=30)
    if made.returncode != 0:
        return False, f"remote Xcode runner unavailable: {made.stderr.strip()}"
    try:
        synced = run_command((
            "rsync", "-a", "--delete", "--exclude=.build", "--exclude=DerivedData",
            str(checkout) + "/", f"{xcode_host}:{remote}/",
        ), timeout=min(timeout, 15 * 60))
        if synced.returncode != 0:
            return False, f"remote sync failed: {synced.stderr[-1000:]}"
        remote_command = (
            "cd " + shlex.quote(remote)
            + " && ./scripts/setup.sh"
            + " && ./scripts/generate-build-info.sh"
            + " && " + shlex.join(command)
            + " && " + shlex.join((
            "xcodebuild", "-project", "GhosttyTabs.xcodeproj", "-scheme", "term-mesh",
            "-configuration", "Debug", "-destination", "platform=macOS", "build",
            ))
        )
        result = run_command(("ssh", xcode_host, remote_command), timeout=timeout)
        log.write(redact_text(result.stdout + result.stderr, checkout))
        return (result.returncode == 0, "passed" if result.returncode == 0 else f"remote Xcode acceptance failed: {(result.stdout + result.stderr)[-1200:]}")
    finally:
        # The target is an exact, controller-created /tmp path.  Never expand a remote variable.
        run_command(("ssh", xcode_host, "rm", "-rf", remote), timeout=30)


def run_acceptance(
    fixture: Fixture, checkout: Path, log: TextIO, timeout: float, *,
    xcode_host: str, run_id: str,
) -> tuple[bool, int, str]:
    started = time.perf_counter()
    with oracle_overlay(fixture, checkout):
        if fixture.acceptance == "homebrew":
            passed, reason = homebrew_acceptance(checkout)
            log.write(reason + "\n")
        elif fixture.acceptance == "ghostty":
            passed, reason = run_logged(
                ("bash", "scripts/test-ghostty-kit-guard.sh"), checkout=checkout,
                log=log, timeout=timeout,
            )
            if passed:
                required = (
                    "scripts/check-ghostty-kit.sh", "scripts/setup.sh", "scripts/reload.sh",
                    "scripts/publish-github-release.sh", "GhosttyTabs.xcodeproj/project.pbxproj",
                )
                missing = [path for path in required if not (checkout / path).exists()]
                wired = not missing and all(
                    "check-ghostty-kit.sh" in (checkout / path).read_text()
                    or "ghostty_kit_is_consistent" in (checkout / path).read_text()
                    for path in required[1:]
                )
                if missing or not wired:
                    passed, reason = False, f"guard boundary mismatch: missing={missing} wired={wired}"
        else:
            passed, reason = run_divider_acceptance(checkout, log, timeout, xcode_host, run_id)
    return passed, round((time.perf_counter() - started) * 1000), reason


class TraceWriter:
    def __init__(self, path: Path, session: str):
        self.path = path
        self.session = session
        self.sequence = 0

    def write(self, event_type: str, **fields: Any) -> None:
        self.sequence += 1
        entry = {
            "v": 1, "seq": self.sequence, "session_id": self.session,
            "timestamp": utc_now(), "type": event_type, **fields,
        }
        with self.path.open("a") as handle:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")


def event_has_action(line: str) -> bool:
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        return False
    message = event.get("message") if isinstance(event.get("message"), dict) else {}
    return any(
        isinstance(block, dict) and block.get("type") == "tool_use"
        for block in message.get("content", []) if isinstance(message.get("content", []), list)
    )


def run_stream(
    command: list[str], *, cwd: Path, timeout: float, log: TextIO, trace: TraceWriter, label: str,
    env: Optional[dict[str, str]] = None,
) -> tuple[subprocess.CompletedProcess[str], Optional[int], int]:
    process = subprocess.Popen(
        command, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        bufsize=1, start_new_session=True, env=env,
    )
    assert process.stdout and process.stderr
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    started = time.perf_counter()
    first_action: Optional[int] = None
    stdout: list[str] = []
    stderr: list[str] = []
    trace.write("agent_call_start", role="leader", label=label, command=command_fingerprint(command))
    try:
        while selector.get_map():
            remaining = timeout - (time.perf_counter() - started)
            if remaining <= 0:
                terminate_process_group(process)
                raise subprocess.TimeoutExpired(command, timeout, "".join(stdout), "".join(stderr))
            for key, _ in selector.select(timeout=min(1.0, remaining)):
                line = key.fileobj.readline()
                if not line:
                    selector.unregister(key.fileobj)
                    continue
                log.write(redact_text(line, cwd))
                log.flush()
                if key.data == "stdout":
                    stdout.append(line)
                    if first_action is None and event_has_action(line):
                        first_action = round((time.perf_counter() - started) * 1000)
                else:
                    stderr.append(line)
        code = process.wait(timeout=5)
    finally:
        selector.close()
        if process.poll() is None:
            terminate_process_group(process)
    duration = round((time.perf_counter() - started) * 1000)
    trace.write("agent_call_end", role="leader", label=label, duration_ms=duration, status="completed" if code == 0 else "failed")
    return subprocess.CompletedProcess(command, code, "".join(stdout), "".join(stderr)), first_action, duration


def terminate_process_group(process: subprocess.Popen[str]) -> None:
    """Stop a streamed agent and every subprocess it launched."""
    if process.poll() is not None:
        return
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def parse_stream(text: str) -> dict[str, Any]:
    final: dict[str, Any] = {}
    for line in text.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "result":
            final = event
    usage = final.get("usage") if isinstance(final.get("usage"), dict) else {}
    tokens = {key: int(usage.get(key, 0) or 0) for key in TOKEN_KEYS}
    return {
        "session_id": final.get("session_id"), "turns": int(final.get("num_turns", 0) or 0),
        "tokens": tokens, "cost_usd": final.get("total_cost_usd"),
    }


def count_worker_dispatches(text: str) -> int:
    """Count actual headless worker sends in a Claude stream."""
    count = 0
    for line in text.splitlines():
        with contextlib.suppress(json.JSONDecodeError):
            event = json.loads(line)
            message = event.get("message", {})
            for block in message.get("content", []) if isinstance(message, dict) else []:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                payload = block.get("input", {})
                command = payload.get("command", "") if isinstance(payload, dict) else ""
                count += len(re.findall(
                    r"(?:^|[\n;&|()])\s*tm-agent\s+send\b", command, re.MULTILINE,
                ))
    return count


def first_tool_dispatch_count(text: str) -> Optional[int]:
    """Return worker sends in the first assistant tool call, if any."""
    for line in text.splitlines():
        with contextlib.suppress(json.JSONDecodeError):
            event = json.loads(line)
            message = event.get("message", {})
            for block in message.get("content", []) if isinstance(message, dict) else []:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                payload = block.get("input", {})
                command = payload.get("command", "") if isinstance(payload, dict) else ""
                return len(re.findall(
                    r"(?:^|[\n;&|()])\s*tm-agent\s+send\b", command, re.MULTILINE,
                ))
    return None


def forbidden_multi_commands(text: str) -> list[str]:
    """Return transcript-sized or app-board tm-agent commands used by a leader."""
    forbidden: list[str] = []
    pattern = re.compile(
        r"(?:^|[\n;&|()])\s*tm-agent\s+"
        r"(read|collect|status|list|wait|send|create|add|destroy)\b"
    )
    # Direct mem-mesh lifecycle hooks may be injected by the host around every
    # Claude turn. They do not let the leader inspect workers or coordinate the
    # benchmark, so only reject attempts to discover/invoke them through a
    # shell/search tool. Monitor and ToolSearch remain forbidden as alternate
    # worker-wait channels.
    auxiliary_pattern = re.compile(r"\b(Monitor|ToolSearch|mcp__mem[-_]mesh)(?=\b|__)")
    for line in text.splitlines():
        with contextlib.suppress(json.JSONDecodeError):
            event = json.loads(line)
            message = event.get("message", {})
            for block in message.get("content", []) if isinstance(message, dict) else []:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                payload = block.get("input", {})
                command = payload.get("command", "") if isinstance(payload, dict) else ""
                forbidden.extend(match.group(1) for match in pattern.finditer(command))
                forbidden.extend(match.group(1) for match in auxiliary_pattern.finditer(command))
                name = block.get("name")
                if isinstance(name, str) and re.search(r"\b(Monitor|ToolSearch)(?=\b|__)", name):
                    forbidden.append(name)
    return forbidden


def add_tokens(target: dict[str, int], addition: dict[str, int]) -> None:
    for key in TOKEN_KEYS:
        target[key] = target.get(key, 0) + int(addition.get(key, 0) or 0)


def tm_environment() -> dict[str, str]:
    """Keep the matching app/task-board and headless-daemon endpoints."""
    env = os.environ.copy()
    for key in ("TERMMESH_WORKSPACE_ID", "TERMMESH_PANEL_ID", "TERMMESH_SURFACE_ID", "TERMMESH_TAB_ID"):
        env.pop(key, None)
    app = env.get("TERMMESH_SOCKET_PATH") or env.get("TERMMESH_SOCKET")
    daemon = env.get("TERMMESH_DAEMON_UNIX_PATH") or env.get("TERMMESH_DAEMON_SOCKET")
    if not app or not Path(app).exists():
        raise RuntimeError("connectable TERMMESH app socket is required")
    if not daemon or not Path(daemon).exists():
        raise RuntimeError("connectable TERMMESH daemon socket is required")
    env["TERMMESH_SOCKET"] = app
    env["TERMMESH_SOCKET_PATH"] = app
    env["TERMMESH_DAEMON_SOCKET"] = daemon
    env["TERMMESH_DAEMON_UNIX_PATH"] = daemon
    return env


def benchmark_agent_environment(checkout: Path) -> tuple[dict[str, str], Path]:
    """Create per-run guards that reject pushes to non-local remotes.

    Candidates may test release scripts, but benchmark execution must never
    mutate GitHub or another external repository. ``GIT_TEMPLATE_DIR`` puts
    this hook into every repository cloned or initialized by the agent while
    still allowing local bare repositories used by hermetic tests.
    """
    guard_root = checkout.parent / f".{checkout.name}-controller-guards"
    hooks = guard_root / "git-template/hooks"
    hooks.mkdir(parents=True, exist_ok=False)
    pre_push = hooks / "pre-push"
    pre_push.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "remote_url=${2:-}\n"
        "case \"$remote_url\" in\n"
        "  /*|./*|../*|file://*) exit 0 ;;\n"
        "esac\n"
        "echo \"term-mesh benchmark: blocked push to external remote: $remote_url\" >&2\n"
        "exit 97\n"
    )
    pre_push.chmod(0o755)
    env = tm_environment()
    env["GIT_TEMPLATE_DIR"] = str(guard_root / "git-template")
    # Protect the already-created fixture checkout too, not only repositories
    # initialized by the candidate after this environment is installed.
    env["GIT_CONFIG_COUNT"] = "1"
    env["GIT_CONFIG_KEY_0"] = "core.hooksPath"
    env["GIT_CONFIG_VALUE_0"] = str(hooks)
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["TERMMESH_BENCHMARK_NO_EXTERNAL_WRITES"] = "1"
    return env, guard_root


@contextlib.contextmanager
def benchmark_run_lock(results_dir: Path) -> Iterator[None]:
    """Allow only one paid effectiveness matrix per results directory."""
    results_dir.mkdir(parents=True, exist_ok=True)
    lock_path = results_dir / ".run.lock"
    with lock_path.open("a+") as handle:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            handle.seek(0)
            owner = handle.read().strip() or "unknown owner"
            raise RuntimeError(
                f"another effectiveness benchmark is already running ({owner})"
            ) from error
        handle.seek(0)
        handle.truncate()
        handle.write(f"pid={os.getpid()} started_at={utc_now()}\n")
        handle.flush()
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


@contextlib.contextmanager
def benchmark_signal_cleanup() -> Iterator[None]:
    """Make an external SIGTERM run every enclosing ``finally`` block."""
    previous = signal.getsignal(signal.SIGTERM)

    def terminate(signum: int, _frame: Any) -> None:
        raise BenchmarkTerminated(f"benchmark interrupted by signal {signum}")

    signal.signal(signal.SIGTERM, terminate)
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous)


def parse_tm_json(output: str) -> Any:
    """Decode the first tm-agent JSON document, ignoring CLI guidance text.

    Commands such as ``create`` print a valid JSON response followed by a
    human-facing ``Commands:`` block on stdout.  ``raw_decode`` preserves the
    structured response without treating that documented guidance as a second
    JSON value.
    """
    stripped = output.lstrip()
    if not stripped:
        raise ValueError("tm-agent returned empty stdout")
    parsed, _ = json.JSONDecoder().raw_decode(stripped)
    return parsed


def tm_json(*args: str, cwd: Path, timeout: float = 120) -> Any:
    result = run_command(("tm-agent", *args), cwd=cwd, timeout=timeout, env=tm_environment())
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    parsed = parse_tm_json(result.stdout)
    if isinstance(parsed, dict) and parsed.get("ok") is False:
        raise RuntimeError(str(parsed.get("error")))
    return parsed.get("result", parsed) if isinstance(parsed, dict) else parsed


def daemon_json(method: str, params: dict[str, Any], *, timeout: float = 10) -> Any:
    daemon = tm_environment()["TERMMESH_DAEMON_SOCKET"]
    request = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}) + "\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(daemon)
        client.sendall(request.encode())
        response = b""
        while b"\n" not in response:
            chunk = client.recv(65536)
            if not chunk:
                break
            response += chunk
    parsed = json.loads(response.split(b"\n", 1)[0].decode())
    if parsed.get("error"):
        raise RuntimeError(str(parsed["error"]))
    return parsed.get("result")


def create_benchmark_team(team: str, checkout: Path, model: str) -> Any:
    """Create three clean Claude workers without user/project customizations.

    ``tm-agent create`` intentionally applies the user's normal CLI profile.
    That is desirable interactively but contaminates an experiment: hooks,
    plugins, MCP servers, and auto-discovered instructions add work and tokens
    unrelated to the assigned condition.  The daemon RPC exposes per-agent
    ``extra_args``, allowing the benchmark to apply the same isolation as the
    directly launched leader.
    """
    app_socket = tm_environment()["TERMMESH_SOCKET"]
    agents = [
        {
            "name": role,
            "agent_type": role,
            "cli": "claude",
            "model": model,
            "extra_args": [
                "--safe-mode",
                "--disable-slash-commands",
                "--strict-mcp-config",
                "--mcp-config",
                '{"mcpServers":{}}',
            ],
        }
        for role in ("explorer", "executor", "reviewer")
    ]
    return daemon_json(
        "headless.create_team",
        {
            "team_name": team,
            "working_directory": str(checkout),
            "leader_session_id": f"benchmark-leader-{os.getpid()}",
            "leader_mode": "claude",
            "leader_model": model,
            "agents": agents,
            "app_socket_path": app_socket,
        },
        timeout=300,
    )


def worker_instruction(fixture: Fixture, team: str, role: str) -> str:
    result_file = f"/tmp/term-mesh-bench-{team}-{role}.result"
    report_file = f"~/.term-mesh/results/{team}/{role}-{uuid.uuid4().hex[:8]}-full.md"
    role_work = {
        "explorer": (
            "read-only 조사 담당이다. 관련 파일과 현재 동작, 최소 수정 지점, 검증 방법을 "
            "찾되 어떤 repo 파일도 수정하지 마라."
        ),
        "executor": (
            "구현 담당이며 필요한 repo 파일을 소유한다. 요구사항을 구현하고 관련 테스트를 "
            "추가하며 가능한 검증을 실행하라. commit은 만들지 마라."
        ),
        "reviewer": (
            "read-only 검토 담당이다. 요구사항의 edge case, 회귀 위험, hidden acceptance가 "
            "확인할 법한 조건과 검증 방법을 분석하되 어떤 repo 파일도 수정하지 마라."
        ),
    }[role]
    return f"""
실제 개발 benchmark worker다. 현재 checkout만 사용하고 git history, benchmark controller, solution
commit, 외부 checkout에서 정답을 찾지 마라. 외부 remote에 push/publish/release하지 마라.

작업: {fixture.prompt}

역할: {role_work}
긴 세부 결과는 먼저 `{report_file}`에 작성하라. 마지막에 아래 정확한 5-line envelope를 stdout에
출력하고, 같은 5줄을 `{result_file}.tmp.$$`에 쓴 뒤 atomic `mv`로 `{result_file}`에 저장하라.
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <수정 파일 또는 none>
VERIFY: <검증 명령 또는 n/a>
NEXT: <leader가 할 한 가지 action 또는 NONE>
FULL_REPORT: {report_file}
""".strip()


def dispatch_benchmark_workers(
    fixture: Fixture, team: str, checkout: Path, trace: TraceWriter, timeout: float = 120,
) -> int:
    """Submit all three worker tasks concurrently and verify each delivery."""
    env = tm_environment()
    roles = ("explorer", "executor", "reviewer")
    started = time.perf_counter()
    processes = {
        role: subprocess.Popen(
            (
                "tm-agent", "send", role, worker_instruction(fixture, team, role),
                "--no-report", "--team", team,
            ),
            cwd=checkout, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
        )
        for role in roles
    }
    delivered = 0
    failures = []
    deadline = time.perf_counter() + timeout
    for role, process in processes.items():
        remaining = max(1, deadline - time.perf_counter())
        try:
            stdout, stderr = process.communicate(timeout=remaining)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate()
            failures.append(f"{role}: dispatch timeout")
            continue
        if process.returncode == 0:
            delivered += 1
        else:
            failures.append(f"{role}: {safe_failure(stderr or stdout)}")
    trace.write(
        "workers_dispatched", count=delivered,
        duration_ms=round((time.perf_counter() - started) * 1000),
    )
    if failures:
        raise RuntimeError("worker dispatch failed: " + "; ".join(failures))
    if delivered != len(roles):
        raise RuntimeError(f"worker dispatch incomplete: {delivered}/{len(roles)}")
    return delivered


def parse_worker_usage(lines: Iterable[Any]) -> tuple[dict[str, int], Optional[float], bool]:
    """Read cumulative usage from the final headless-worker result event.

    Claude's ``usage`` object describes only the latest invocation, while
    ``modelUsage`` is cumulative for the persistent session.  Using only the
    final result avoids double-counting earlier turns returned by ``tm-agent
    read``.
    """
    final: Optional[dict[str, Any]] = None
    for raw in lines:
        if isinstance(raw, dict):
            event = raw
        elif isinstance(raw, str):
            with contextlib.suppress(json.JSONDecodeError):
                event = json.loads(raw)
                if isinstance(event, dict) and event.get("type") == "result":
                    final = event
            continue
        else:
            continue
        if event.get("type") == "result":
            final = event
    if final is None:
        return {key: 0 for key in TOKEN_KEYS}, None, False

    totals = {key: 0 for key in TOKEN_KEYS}
    cost = 0.0
    cost_observed = False
    model_usage = final.get("modelUsage")
    if isinstance(model_usage, dict) and model_usage:
        mapping = {
            "input_tokens": "inputTokens",
            "output_tokens": "outputTokens",
            "cache_read_input_tokens": "cacheReadInputTokens",
            "cache_creation_input_tokens": "cacheCreationInputTokens",
        }
        for usage in model_usage.values():
            if not isinstance(usage, dict):
                continue
            for target, source in mapping.items():
                totals[target] += int(usage.get(source, 0) or 0)
            if usage.get("costUSD") is not None:
                cost += float(usage["costUSD"])
                cost_observed = True
    else:
        usage = final.get("usage") if isinstance(final.get("usage"), dict) else {}
        add_tokens(totals, usage)
        raw_cost = final.get("total_cost_usd")
        if raw_cost is not None:
            cost = float(raw_cost)
            cost_observed = True
    return totals, cost if cost_observed else None, True


def team_usage(
    team: str, checkout: Path, workers: Iterable[str] = ("explorer", "executor", "reviewer"),
) -> tuple[dict[str, int], float, int, int]:
    """Read daemon-persisted cumulative worker usage without transcript size limits.

    ``headless.read`` returns full NDJSON events and can exceed the daemon's
    64 KiB response envelope even at a small line count.  The daemon already
    persists the same monotonic counters to agent metadata every 30 seconds,
    and flushes them during lifecycle transitions.
    """
    totals = {key: 0 for key in TOKEN_KEYS}
    observed = 0
    worker_names = tuple(workers)
    root = Path(os.environ.get("TERMMESH_HEADLESS_ROOT", Path.home() / ".term-mesh/headless"))
    team_dir: Optional[Path] = None
    for metadata in root.glob("*/team.json"):
        with contextlib.suppress(OSError, json.JSONDecodeError):
            payload = json.loads(metadata.read_text())
            if payload.get("team_name") == team:
                team_dir = metadata.parent
                break
    if team_dir is None:
        return totals, 0.0, observed, len(worker_names)
    for worker in worker_names:
        with contextlib.suppress(OSError, json.JSONDecodeError):
            payload = json.loads((team_dir / "agents" / f"{worker}.json").read_text())
            usage = payload.get("usage_total")
            if not isinstance(usage, dict):
                continue
            add_tokens(totals, usage)
            observed += 1
    return totals, 0.0, observed, len(worker_names)


def usage_delta(after: dict[str, int], before: dict[str, int]) -> dict[str, int]:
    return {key: max(0, int(after.get(key, 0)) - int(before.get(key, 0))) for key in TOKEN_KEYS}


def estimate_cost(tokens: dict[str, int], model: str) -> Optional[float]:
    family = next((name for name in MODEL_PRICING_PER_MTOK if name in model.lower()), None)
    if family is None:
        return None
    rates = MODEL_PRICING_PER_MTOK[family]
    output = int(tokens.get("output_tokens", 0)) + int(tokens.get("reasoning_output_tokens", 0))
    total = (
        int(tokens.get("input_tokens", 0)) * rates["input"]
        + output * rates["output"]
        + int(tokens.get("cache_read_input_tokens", 0)) * rates["cache_read"]
        + int(tokens.get("cache_creation_input_tokens", 0)) * rates["cache_write"]
    ) / 1_000_000
    return round(total, 6)


def leader_prompt(
    fixture: Fixture, condition: str, team: Optional[str], worker_headers: Optional[str] = None,
) -> str:
    common = f"""
실제 개발 benchmark다. 현재 checkout에 보이는 정보만 사용하라. git history, benchmark
controller, solution commit, 외부 checkout에서 정답을 찾지 마라. 문제를 수정하고 관련 테스트를
추가한 뒤 가능한 검증을 실행하라. commit은 만들지 마라. 완료 기준은 working tree의 동작이다.
외부 remote에 push, publish, release하거나 외부 서비스를 변경하지 마라. release script 테스트는
반드시 local bare repository와 stub command만 사용하는 hermetic test로 작성하라.

작업: {fixture.prompt}
""".strip()
    if condition == "single":
        return common + "\n\nSub-agent와 tm-agent를 사용하지 말고 이 한 session에서 직접 완료하라."
    assert team
    headers = worker_headers or "worker result envelope가 아직 없다. leader가 직접 구현을 완료하라."
    protocol = f"""
controller가 explorer, executor, reviewer 세 worker를 이미 동시에 dispatch하고 최대 15분 기다렸다.
explorer와 reviewer는 read-only이고 executor만 구현 파일을 소유한다. 아래 worker envelope를 참고하고
필요할 때만 그 안의 FULL_REPORT를 읽어 통합·수정·최종 검증하라. 누락 worker를 다시 기다리거나
result 파일을 재조회하지 말고 leader가 직접 남은 일을 끝내라. 어떤 `tm-agent` 명령도 호출하지 마라.
`Monitor`, background task, `ToolSearch`, mem-mesh, `delegate`, `task`도 사용하지 마라. 세 worker는 이
checkout을 공유한다. 통합과 최종 검증은 leader가 책임진다.

worker envelopes:
{headers}
""".strip()
    return protocol + "\n\n" + common


def wait_for_worker_results(
    result_files: list[Path], *, timeout: float, trace: Optional[TraceWriter] = None,
) -> tuple[str, int, int]:
    """Wait once in the controller and return bounded worker envelopes."""
    started = time.perf_counter()
    deadline = started + max(0, timeout)
    while time.perf_counter() < deadline:
        if all(path.is_file() and path.stat().st_size > 0 for path in result_files):
            break
        time.sleep(min(0.25, max(0, deadline - time.perf_counter())))
    elapsed_ms = round((time.perf_counter() - started) * 1000)
    sections = []
    ready = 0
    for path in result_files:
        if path.is_file() and path.stat().st_size > 0:
            ready += 1
            lines = path.read_text(errors="replace").splitlines()[:8]
            sections.append(f"=== {path.name} ===\n" + "\n".join(lines))
        else:
            sections.append(f"=== {path.name} ===\nSTATUS: BLOCKED\nNEXT: leader가 직접 완료")
    if trace is not None:
        trace.write("workers_waited", ready=ready, expected=len(result_files), duration_ms=elapsed_ms)
    return "\n".join(sections), elapsed_ms, ready


def claude_command(
    prompt: str, *, model: str, effort: str, session_id: str, resume: bool, condition: str,
) -> list[str]:
    command = [
        "claude", "-p", prompt, "--output-format", "stream-json", "--verbose",
        "--model", model, "--effort", effort, "--permission-mode", "bypassPermissions",
        "--dangerously-skip-permissions", "--safe-mode", "--disable-slash-commands",
        "--strict-mcp-config",
        "--mcp-config", '{"mcpServers":{}}',
    ]
    command.extend(("--resume", session_id) if resume else ("--session-id", session_id))
    disallowed = "Agent,Task" if condition == "single" else "Agent,Task,Monitor,ToolSearch"
    command.extend(("--disallowedTools", disallowed))
    return command


def safe_failure(reason: str) -> str:
    return redact_text(reason)[-1800:]


def redact_text(text: str, checkout: Optional[Path] = None) -> str:
    text = re.sub(
        r"(?i)\b(token|secret|password|authorization|api[_-]?key)\b([=:]\s*|\s+)([^\s'\"]+)",
        lambda match: f"{match.group(1)}{match.group(2)}<redacted>", text,
    )
    text = text.replace(str(Path.home()), "<HOME>")
    if checkout is not None:
        text = text.replace(str(checkout), "<checkout>")
    return text


def parse_timestamp(value: Any) -> Optional[datetime]:
    if not isinstance(value, str) or not value:
        return None
    with contextlib.suppress(ValueError):
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    return None


def worker_timing(task_rows: list[dict[str, Any]]) -> tuple[Optional[int], Optional[float]]:
    """Return union wall span and summed-active/span when task timestamps exist."""
    intervals: list[tuple[datetime, datetime]] = []
    for row in task_rows:
        started = next((parse_timestamp(row.get(key)) for key in ("started_at", "assigned_at", "created_at") if parse_timestamp(row.get(key))), None)
        finished = next((parse_timestamp(row.get(key)) for key in ("completed_at", "finished_at", "updated_at") if parse_timestamp(row.get(key))), None)
        if started and finished and finished >= started:
            intervals.append((started, finished))
    if not intervals:
        return None, None
    span_ms = max(1, round((max(end for _, end in intervals) - min(start for start, _ in intervals)).total_seconds() * 1000))
    active_ms = sum(round((end - start).total_seconds() * 1000) for start, end in intervals)
    return span_ms, round(active_ms / (span_ms * max(1, len(intervals))), 3)


def classify_infra_failure(reason: str) -> bool:
    return bool(re.search(
        r"provider|overloaded|rate limit|authentication|connection reset|network is unreachable|"
        r"remote Xcode runner unavailable|snapshot setup failed|submodule failed|daemon.*unavailable|"
        r"team not found|socket.*(?:missing|unavailable|refused)|"
        r"BenchmarkTerminated|benchmark interrupted by signal",
        reason, re.IGNORECASE,
    ))


def write_patch(checkout: Path, destination: Path) -> int:
    run_command(("git", "add", "-N", "."), cwd=checkout, timeout=60)
    destination.write_text(git("diff", "--binary", cwd=checkout))
    names = git("diff", "--name-only", cwd=checkout)
    return len([line for line in names.splitlines() if line])


def run_one(
    spec: RunSpec, *, experiment: Path, scratch: Path, model: str, effort: str,
    timeout: int, xcode_host: str, keep_checkouts: bool,
) -> RunResult:
    fixture = FIXTURES[spec.fixture]
    run_id = f"{fixture.name}-{spec.condition}-t{spec.trial}-{uuid.uuid4().hex[:8]}"
    run_dir = experiment / "runs" / run_id
    run_dir.mkdir(parents=True)
    checkout = scratch / run_id
    relative_run = Path("runs") / run_id
    paths = {
        "result": str(relative_run / "result.json"), "trace": str(relative_run / "trace.jsonl"),
        "patch": str(relative_run / "candidate.patch"), "stdout": str(relative_run / "stdout.log"),
        "acceptance": str(relative_run / "acceptance.log"),
    }
    record = RunResult(
        run_id=run_id, fixture=fixture.name, parallelism=fixture.parallelism, trial=spec.trial,
        condition=spec.condition, order=spec.order, started_at=utc_now(),
        tokens={key: 0 for key in TOKEN_KEYS}, paths=paths,
    )
    trace = TraceWriter(experiment / paths["trace"], run_id)
    team: Optional[str] = None
    result_files: list[Path] = []
    guard_root: Optional[Path] = None
    total_started: Optional[float] = None
    try:
        # Fixture materialization and cache warm-up are deliberately outside the timer.
        create_snapshot(fixture, checkout)
        agent_env, guard_root = benchmark_agent_environment(checkout)
        session_id = str(uuid.uuid4())
        total_started = time.perf_counter()
        trace.write("session_start", condition=spec.condition, fixture=fixture.name, model=model, effort=effort)
        if spec.condition == "multi":
            team = f"bench-{uuid.uuid4().hex[:10]}"
            result_files = [
                Path(f"/tmp/term-mesh-bench-{team}-{worker}.result")
                for worker in ("explorer", "executor", "reviewer")
            ]
            for result_file in result_files:
                result_file.unlink(missing_ok=True)
            init_started = time.perf_counter()
            create_benchmark_team(team, checkout, model)
            record.team_init_ms = round((time.perf_counter() - init_started) * 1000)
            trace.write("team_ready", workers=3, duration_ms=record.team_init_ms)
            record.worker_tasks = dispatch_benchmark_workers(
                fixture, team, checkout, trace, timeout=min(timeout, 120),
            )
            remaining = timeout - (time.perf_counter() - total_started)
            worker_headers, worker_wait_ms, _ = wait_for_worker_results(
                result_files, timeout=min(15 * 60, max(0, remaining)), trace=trace,
            )
            record.worker_active_critical_path_ms = worker_wait_ms
        else:
            worker_headers = None
        active_started = time.perf_counter()
        prompt = leader_prompt(fixture, spec.condition, team, worker_headers)
        with (experiment / paths["stdout"]).open("w") as stdout_log, (experiment / paths["acceptance"]).open("w") as acceptance_log:
            resume = False
            while True:
                elapsed = time.perf_counter() - total_started
                remaining = timeout - elapsed
                if remaining <= 0:
                    record.timed_out = True
                    record.failure_reason = f"end-to-end timeout after {timeout}s"
                    break
                command = claude_command(
                    prompt, model=model, effort=effort, session_id=session_id, resume=resume,
                    condition=spec.condition,
                )
                try:
                    completed, first_action, duration = run_stream(
                        command, cwd=checkout, timeout=remaining, log=stdout_log, trace=trace,
                        label="correction" if resume else "initial", env=agent_env,
                    )
                except subprocess.TimeoutExpired:
                    record.timed_out = True
                    record.failure_reason = f"leader timeout after {timeout}s"
                    break
                if record.time_to_first_action_ms is None:
                    record.time_to_first_action_ms = first_action
                parsed = parse_stream(completed.stdout)
                if spec.condition == "multi":
                    forbidden = forbidden_multi_commands(completed.stdout)
                    if forbidden:
                        record.failure_reason = (
                            "multi protocol violation: forbidden tm-agent commands: "
                            + ", ".join(sorted(set(forbidden)))
                        )
                add_tokens(record.tokens, parsed["tokens"])
                record.leader_turns += parsed["turns"]
                if parsed["cost_usd"] is not None:
                    record.cost_usd = (record.cost_usd or 0.0) + float(parsed["cost_usd"])
                    record.cost_precision = "actual_all" if spec.condition == "single" else "leader_actual_workers_unavailable"
                if completed.returncode != 0:
                    record.failure_reason = safe_failure(completed.stderr or f"leader exit {completed.returncode}")
                    break
                if record.failure_reason and record.failure_reason.startswith("multi protocol violation"):
                    break
                if spec.condition == "multi" and record.worker_tasks < 3:
                    record.failure_reason = (
                        "multi protocol violation: leader completed without dispatching all "
                        f"three workers (observed {record.worker_tasks} tm-agent send commands)"
                    )
                    break
                remaining = timeout - (time.perf_counter() - total_started)
                if remaining <= 0:
                    record.timed_out = True
                    record.failure_reason = f"end-to-end timeout after {timeout}s"
                    break
                trace.write("acceptance_start", attempt=record.correction_count + 1)
                passed, acceptance_ms, reason = run_acceptance(
                    fixture, checkout, acceptance_log, remaining, xcode_host=xcode_host, run_id=run_id,
                )
                record.acceptance_ms += acceptance_ms
                trace.write("acceptance_end", attempt=record.correction_count + 1, duration_ms=acceptance_ms, status="passed" if passed else "failed")
                if passed:
                    record.acceptance_passed = True
                    record.status = "passed"
                    record.failure_reason = None
                    break
                record.failure_reason = safe_failure(reason)
                record.correction_count += 1
                prompt = (
                    "숨은 acceptance가 실패했다. 같은 작업과 session을 이어서 수정하고 검증하라. "
                    "다른 정답이나 git history는 찾지 마라. 실패 항목:\n" + record.failure_reason
                )
                resume = True
            record.active_task_ms = round((time.perf_counter() - active_started) * 1000)
        record.total_wall_ms = round((time.perf_counter() - total_started) * 1000)
        if team:
            trace.write("worker_dispatch_summary", count=record.worker_tasks)
            worker_tokens, _, observed, expected = team_usage(team, checkout)
            add_tokens(record.tokens, worker_tokens)
            worker_cost = estimate_cost(worker_tokens, model) if observed else None
            if worker_cost is not None:
                record.cost_usd = (record.cost_usd or 0.0) + worker_cost
            if observed == expected:
                record.token_precision = "actual_all"
                record.cost_precision = "leader_actual_workers_estimate"
            elif observed:
                record.token_precision = "leader_actual_workers_partial"
                record.cost_precision = "leader_actual_workers_partial_estimate"
            else:
                record.token_precision = "leader_actual_workers_unavailable"
                record.cost_precision = "leader_actual_workers_unavailable"
        elif record.cost_usd is None:
            record.cost_usd = estimate_cost(record.tokens, model)
            if record.cost_usd is not None:
                record.cost_precision = "token_estimate"
        record.changed_files = write_patch(checkout, experiment / paths["patch"])
        if record.status != "passed":
            record.status = "timeout" if record.timed_out else "failed"
            record.infra_invalid = classify_infra_failure(record.failure_reason or "")
    except KeyboardInterrupt as error:
        record.failure_reason = safe_failure(f"KeyboardInterrupt: {error or 'benchmark controller interrupted'}")
        record.infra_invalid = True
        record.status = "infra_invalid"
        if total_started is not None:
            record.total_wall_ms = round((time.perf_counter() - total_started) * 1000)
        with contextlib.suppress(Exception):
            if checkout.exists():
                record.changed_files = write_patch(checkout, experiment / paths["patch"])
    except Exception as error:
        record.failure_reason = safe_failure(f"{type(error).__name__}: {error}")
        record.infra_invalid = classify_infra_failure(record.failure_reason)
        record.status = "infra_invalid" if record.infra_invalid else "failed"
        with contextlib.suppress(Exception):
            if checkout.exists():
                record.changed_files = write_patch(checkout, experiment / paths["patch"])
    finally:
        if team and checkout.exists():
            with contextlib.suppress(Exception):
                daemon_json("headless.destroy_team", {"team_name": team}, timeout=90)
        record.finished_at = utc_now()
        trace.write("session_end", status=record.status, total_wall_ms=record.total_wall_ms, tokens=record.tokens)
        (experiment / paths["result"]).write_text(json.dumps(asdict(record), indent=2, ensure_ascii=False) + "\n")
        if checkout.exists() and not keep_checkouts:
            shutil.rmtree(checkout, ignore_errors=True)
        if guard_root is not None:
            shutil.rmtree(guard_root, ignore_errors=True)
        for result_file in result_files:
            result_file.unlink(missing_ok=True)
    return record


def apply_solution(fixture: Fixture, checkout: Path) -> None:
    patch = subprocess.run(
        ("git", "diff", "--binary", f"{fixture.solution}^", fixture.solution),
        cwd=ROOT, capture_output=True, check=True,
    ).stdout
    result = subprocess.run(("git", "apply", "--binary", "-"), cwd=checkout, input=patch, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(f"oracle patch apply failed: {result.stderr.decode(errors='replace')}")


def validate_suite(
    *, output: Path, xcode_host: str, keep_checkouts: bool, fixtures: Iterable[str] = FIXTURES,
) -> dict[str, Any]:
    selected = tuple(fixtures)
    metadata = [row for row in validate_fixture_metadata() if row["fixture"] in selected]
    output.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="term-mesh-effectiveness-validate-"))
    rows = []
    try:
        for name in selected:
            fixture = FIXTURES[name]
            checkout = scratch / fixture.name
            create_snapshot(fixture, checkout, prepare=fixture.acceptance == "divider")
            log_path = output / f"{fixture.name}.log"
            with log_path.open("w") as log:
                baseline, _, baseline_reason = run_acceptance(
                    fixture, checkout, log, DEFAULT_TIMEOUT, xcode_host=xcode_host, run_id=f"validate-{fixture.name}-base",
                )
                apply_solution(fixture, checkout)
                oracle, _, oracle_reason = run_acceptance(
                    fixture, checkout, log, DEFAULT_TIMEOUT, xcode_host=xcode_host, run_id=f"validate-{fixture.name}-oracle",
                )
            baseline_infra = classify_infra_failure(baseline_reason)
            oracle_infra = classify_infra_failure(oracle_reason)
            row = {
                "fixture": fixture.name, "baseline_failed": not baseline, "oracle_passed": oracle,
                "infra_invalid": baseline_infra or oracle_infra,
                "history_isolated": run_command(("git", "cat-file", "-e", fixture.solution), cwd=checkout).returncode != 0,
                "baseline_reason": safe_failure(baseline_reason), "oracle_reason": safe_failure(oracle_reason),
            }
            rows.append(row)
    finally:
        if not keep_checkouts:
            shutil.rmtree(scratch, ignore_errors=True)
    result = {"schema": 1, "validated_at": utc_now(), "metadata": metadata, "fixtures": rows}
    result["passed"] = all(
        not row["infra_invalid"] and row["baseline_failed"]
        and row["oracle_passed"] and row["history_isolated"] for row in rows
    )
    (output / "suite-validation.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    return result


def percentile(values: list[float], q: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * q
    low = int(position)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def bootstrap_ci(values: list[float], *, seed: int, samples: int = 10_000) -> list[Optional[float]]:
    if not values:
        return [None, None]
    rng = random.Random(seed)
    estimates = [statistics.median(rng.choices(values, k=len(values))) for _ in range(samples)]
    return [percentile(estimates, 0.025), percentile(estimates, 0.975)]


def pair_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows = latest_effectiveness_rows(rows)
    grouped: dict[tuple[str, int], dict[str, dict[str, Any]]] = {}
    for row in rows:
        if row.get("infra_invalid"):
            continue
        grouped.setdefault((row["fixture"], int(row["trial"])), {})[row["condition"]] = row
    pairs = []
    for (fixture, trial), conditions in sorted(grouped.items()):
        if set(conditions) != set(CONDITIONS):
            continue
        single, multi = conditions["single"], conditions["multi"]
        valid_latency = bool(single.get("acceptance_passed") and multi.get("acceptance_passed"))
        speedup = None
        if valid_latency and single.get("total_wall_ms") and multi.get("total_wall_ms"):
            speedup = single["total_wall_ms"] / multi["total_wall_ms"]
        single_tokens = sum(int(single.get("tokens", {}).get(key, 0) or 0) for key in TOKEN_KEYS)
        multi_tokens = sum(int(multi.get("tokens", {}).get(key, 0) or 0) for key in TOKEN_KEYS)
        single_cost = single.get("cost_usd")
        multi_cost = multi.get("cost_usd")
        pairs.append({
            "fixture": fixture, "parallelism": FIXTURES[fixture].parallelism, "trial": trial,
            "single_passed": bool(single.get("acceptance_passed")),
            "multi_passed": bool(multi.get("acceptance_passed")),
            "speedup": speedup,
            "token_amplification": (multi_tokens / single_tokens) if single_tokens else None,
            "cost_ratio": (float(multi_cost) / float(single_cost)) if single_cost and multi_cost is not None else None,
            "single_run_id": single["run_id"], "multi_run_id": multi["run_id"],
        })
    return pairs


def quality_index(quality: Optional[dict[str, Any]]) -> dict[tuple[str, int], dict[str, Any]]:
    if not quality:
        return {}
    return {(row["fixture"], int(row["trial"])): row for row in quality.get("comparisons", [])}


def summarize(rows: list[dict[str, Any]], *, seed: int, quality: Optional[dict[str, Any]] = None) -> dict[str, Any]:
    attempts = rows
    usable = latest_effectiveness_rows(rows)
    conditions: dict[str, Any] = {}
    for condition in CONDITIONS:
        selected = [row for row in usable if row["condition"] == condition]
        passed = [row for row in selected if row.get("acceptance_passed")]
        latencies = [float(row["total_wall_ms"]) for row in passed if row.get("total_wall_ms") is not None]
        tokens = [sum(int(row.get("tokens", {}).get(key, 0) or 0) for key in TOKEN_KEYS) for row in passed]
        costs = [float(row["cost_usd"]) for row in passed if row.get("cost_usd") is not None]
        conditions[condition] = {
            "runs": len(selected), "passed": len(passed),
            "pass_rate": len(passed) / len(selected) if selected else None,
            "median_wall_ms": statistics.median(latencies) if latencies else None,
            "wall_iqr_ms": [percentile(latencies, 0.25), percentile(latencies, 0.75)],
            "median_tokens": statistics.median(tokens) if tokens else None,
            "median_cost_usd": statistics.median(costs) if costs else None,
            "median_corrections": statistics.median(
                int(row.get("correction_count", 0) or 0) for row in selected
            ) if selected else None,
            "timeouts": sum(bool(row.get("timed_out")) for row in selected),
        }
    pairs = pair_rows(usable)
    qindex = quality_index(quality)
    for pair in pairs:
        pair["quality"] = qindex.get((pair["fixture"], pair["trial"]))
    speedups = [float(pair["speedup"]) for pair in pairs if pair["speedup"] is not None]
    token_amps = [float(pair["token_amplification"]) for pair in pairs if pair["token_amplification"] is not None]
    cost_ratios = [float(pair["cost_ratio"]) for pair in pairs if pair["cost_ratio"] is not None]
    successful_pairs = [pair for pair in pairs if pair["single_passed"] and pair["multi_passed"]]
    quality_ready = bool(quality) and bool(successful_pairs) and all(
        pair.get("quality")
        and int(pair["quality"].get("valid_judges", 0)) >= 3
        and pair["quality"].get("multi_regression") is not None
        for pair in successful_pairs
    )
    quality_regression = any(
        bool((pair.get("quality") or {}).get("multi_regression")) for pair in pairs
    ) if quality_ready else None
    overall_speedup = statistics.median(speedups) if speedups else None
    pass_not_lower = (
        conditions["single"]["pass_rate"] is not None
        and conditions["multi"]["pass_rate"] is not None
        and conditions["multi"]["pass_rate"] >= conditions["single"]["pass_rate"]
    )
    complete_experiment = (
        conditions["single"]["runs"] >= len(FIXTURES) * 3
        and conditions["multi"]["runs"] >= len(FIXTURES) * 3
        and len(pairs) >= len(FIXTURES) * 3
    )
    default_multi = bool(
        complete_experiment and pass_not_lower and overall_speedup is not None
        and overall_speedup >= 1.20 and quality_regression is False
    )
    routes: dict[str, str] = {}
    for fixture in FIXTURES:
        all_fixture_pairs = [pair for pair in pairs if pair["fixture"] == fixture]
        latency_pairs = [pair for pair in all_fixture_pairs if pair["speedup"] is not None]
        values = [float(pair["speedup"]) for pair in latency_pairs]
        judged = [pair for pair in all_fixture_pairs if pair["single_passed"] and pair["multi_passed"]]
        no_regression = bool(judged) and all(
            pair.get("quality") and not pair["quality"].get("multi_regression") for pair in judged
        )
        single_passes = sum(pair["single_passed"] for pair in all_fixture_pairs)
        multi_passes = sum(pair["multi_passed"] for pair in all_fixture_pairs)
        enough_evidence = len(all_fixture_pairs) >= 3
        routes[fixture] = "multi" if (
            enough_evidence and values and statistics.median(values) >= 1.15
            and no_regression and multi_passes >= single_passes
        ) else "single"
    return {
        "conditions": conditions, "pairs": pairs,
        "paired_speedup_median": overall_speedup,
        "paired_speedup_bootstrap_95ci": bootstrap_ci(speedups, seed=seed),
        "token_amplification_median": statistics.median(token_amps) if token_amps else None,
        "cost_ratio_median": statistics.median(cost_ratios) if cost_ratios else None,
        "quality_ready": quality_ready, "quality_regression": quality_regression,
        "complete_experiment": complete_experiment,
        "default_route": "multi" if default_multi else "single",
        "default_gate_passed": default_multi, "fixture_routes": routes,
        "attempt_runs": len(attempts), "usable_runs": len(usable),
        "infra_invalid_runs": sum(
            bool(row.get("infra_invalid")) or row.get("total_wall_ms") is None
            for row in attempts
        ),
    }


def parse_judge_output(raw: str) -> dict[str, Any]:
    match = re.search(r"\{.*\}", raw, re.DOTALL)
    if not match:
        raise ValueError("judge returned no JSON object")
    parsed = json.loads(match.group(0))
    if parsed.get("winner") not in {"A", "B", "tie"}:
        raise ValueError("judge winner must be A, B, or tie")
    criteria = {"correctness", "maintainability", "test_coverage", "scope_fit"}
    for candidate in ("A", "B"):
        scores = parsed.get(candidate)
        if not isinstance(scores, dict) or set(scores) != criteria:
            raise ValueError(f"judge {candidate} scores must contain exactly {sorted(criteria)}")
        if any(not isinstance(value, (int, float)) or isinstance(value, bool) or not 1 <= value <= 5 for value in scores.values()):
            raise ValueError(f"judge {candidate} scores must be numeric values from 1 to 5")
    return parsed


def quality_prompt(fixture: Fixture, a_patch: str, b_patch: str) -> str:
    return f"""
두 candidate patch를 구현 조건 이름이나 실행 방식 추측 없이 비교하라. deterministic acceptance는
둘 다 통과했다. correctness, maintainability, test_coverage, scope_fit을 각 1~5점으로 평가하라.
JSON만 출력하라: {{"winner":"A|B|tie","A":{{"correctness":N,"maintainability":N,
"test_coverage":N,"scope_fit":N}},"B":{{...}},"reason":"한 문장"}}

TASK:
{fixture.prompt}

CANDIDATE A:
{a_patch}

CANDIDATE B:
{b_patch}
""".strip()


def evaluate_quality(experiment: Path, rows: list[dict[str, Any]], seed: int) -> dict[str, Any]:
    detect = run_command(("xm", "panel", "detect", "--auth", "--json"), timeout=60)
    available: list[str] = []
    if detect.returncode == 0:
        with contextlib.suppress(Exception):
            available = list(json.loads(detect.stdout).get("available", []))
    cross_vendor = len(available) >= 2
    if not available:
        if not shutil.which("claude"):
            raise RuntimeError("no ready quality judge CLI")
        available = ["claude"]
    judges = available[:3]
    while len(judges) < 3:
        judges.append(available[len(judges) % len(available)])
    by_id = {row["run_id"]: row for row in rows}
    comparisons = []
    rng = random.Random(seed)
    eval_dir = experiment / "quality"
    eval_dir.mkdir(exist_ok=True)
    for pair in pair_rows(rows):
        if not (pair["single_passed"] and pair["multi_passed"]):
            continue
        patches = {
            "single": (experiment / by_id[pair["single_run_id"]]["paths"]["patch"]).read_text(),
            "multi": (experiment / by_id[pair["multi_run_id"]]["paths"]["patch"]).read_text(),
        }
        results = []
        starting_order = ["single", "multi"] if rng.random() < 0.5 else ["multi", "single"]
        for index, vendor in enumerate(judges):
            order = starting_order if index % 2 == 0 else list(reversed(starting_order))
            prompt_path = eval_dir / f"{pair['fixture']}-t{pair['trial']}-j{index + 1}.txt"
            prompt_path.write_text(quality_prompt(FIXTURES[pair["fixture"]], patches[order[0]], patches[order[1]]))
            judged = run_command((
                "xm", "panel", "cross", "--models", vendor, "--prompt-file", str(prompt_path),
                "--json", "--source", "eval:judge", "--title", f"effectiveness {pair['fixture']} t{pair['trial']}",
            ), timeout=20 * 60)
            raw = judged.stdout
            with contextlib.suppress(Exception):
                payload = json.loads(raw)
                raw = payload.get("results", [{}])[0].get("output", raw)
            if judged.returncode != 0:
                results.append({"vendor": vendor, "ok": False, "error": safe_failure(judged.stderr)})
                continue
            parsed = parse_judge_output(raw)
            scores: dict[str, Any] = {}
            for label, condition in zip(("A", "B"), order):
                scores[condition] = parsed[label]
            winner = parsed["winner"]
            mapped = "tie" if winner == "tie" else order[0 if winner == "A" else 1]
            results.append({"vendor": vendor, "ok": True, "order": order, "winner": mapped, "scores": scores})
        good = [result for result in results if result.get("ok")]
        def total(condition: str) -> float:
            values = [statistics.mean(float(v) for v in row["scores"][condition].values()) for row in good]
            return statistics.mean(values) if values else 0.0
        single_score, multi_score = total("single"), total("multi")
        comparisons.append({
            "fixture": pair["fixture"], "trial": pair["trial"], "judges": results,
            "single_score": single_score, "multi_score": multi_score,
            "valid_judges": len(good),
            "multi_regression": (multi_score + 0.25 < single_score) if len(good) >= 3 else None,
        })
    result = {
        "schema": 1, "evaluated_at": utc_now(), "cross_vendor": cross_vendor,
        "vendors": judges, "fallback": None if cross_vendor else "fewer than two ready vendors",
        "comparisons": comparisons,
    }
    (experiment / "quality-eval.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    return result


def load_experiment(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if path.is_file():
        path = path.parent
    manifest = json.loads((path / "manifest.json").read_text())
    rows = [json.loads(result.read_text()) for result in sorted((path / "runs").glob("*/result.json"))]
    return manifest, rows


def spec_key(spec: RunSpec | dict[str, Any]) -> tuple[str, int, str]:
    if isinstance(spec, RunSpec):
        return spec.fixture, spec.trial, spec.condition
    return str(spec["fixture"]), int(spec["trial"]), str(spec["condition"])


def completed_spec_keys(rows: Iterable[dict[str, Any]]) -> set[tuple[str, int, str]]:
    """Cells with a durable result survive controller SIGKILL/restart."""
    return {
        spec_key(row)
        for row in rows
        if row.get("total_wall_ms") is not None and not row.get("infra_invalid")
    }


def latest_effectiveness_rows(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Return one usable result per matrix cell, preferring the latest attempt."""
    selected: dict[tuple[str, int, str], dict[str, Any]] = {}
    for row in rows:
        if row.get("total_wall_ms") is None or row.get("infra_invalid"):
            continue
        key = spec_key(row)
        current = selected.get(key)
        if current is None or str(row.get("finished_at", "")) >= str(current.get("finished_at", "")):
            selected[key] = row
    return [selected[key] for key in sorted(selected)]


def resume_manifest_errors(
    manifest: dict[str, Any], *, specs: list[RunSpec], args: argparse.Namespace,
) -> list[str]:
    expected = {
        "model": args.model, "effort": args.effort, "workers": args.workers,
        "trials": args.trials, "seed": args.seed, "timeout_seconds": args.timeout,
        "xcode_host": args.xcode_host, "infra_retries": args.infra_retries,
        "matrix": [asdict(spec) for spec in specs],
    }
    return [
        f"{key}: existing={manifest.get(key)!r} requested={value!r}"
        for key, value in expected.items() if manifest.get(key) != value
    ]


def render_report(experiment: Path, manifest: dict[str, Any], rows: list[dict[str, Any]], summary: dict[str, Any]) -> str:
    def value(number: Optional[float], suffix: str = "") -> str:
        return "-" if number is None else f"{number:.2f}{suffix}"
    lines = [
        "# Single session vs multi-agent effectiveness", "",
        f"- Experiment: `{manifest['run_id']}`",
        f"- Model/effort: `{manifest['model']}` / `{manifest['effort']}`",
        f"- Usable cells: {summary['usable_runs']} / {len(manifest['matrix'])} "
        f"({summary['attempt_runs']} attempts, infra-invalid/incomplete {summary['infra_invalid_runs']})", "",
        "## Result", "",
        f"Default route: **{summary['default_route']}**",
        f"Paired median speedup (single/multi): {value(summary['paired_speedup_median'], 'x')}",
        f"Bootstrap 95% CI: {summary['paired_speedup_bootstrap_95ci']}",
        f"Median token amplification: {value(summary['token_amplification_median'], 'x')}",
        f"Median cost ratio: {value(summary['cost_ratio_median'], 'x')}",
        f"Quality evaluation ready: {summary['quality_ready']} (regression={summary['quality_regression']})", "",
        "## Conditions", "",
        "| condition | pass | median wall | median tokens | median cost | corrections | timeouts |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for condition in CONDITIONS:
        item = summary["conditions"][condition]
        wall = "-" if item["median_wall_ms"] is None else f"{item['median_wall_ms'] / 1000:.1f}s"
        cost = "-" if item["median_cost_usd"] is None else f"${item['median_cost_usd']:.3f}"
        lines.append(
            f"| {condition} | {item['passed']}/{item['runs']} | {wall} | "
            f"{item['median_tokens'] or '-'} | {cost} | {item['median_corrections'] or 0} | {item['timeouts']} |"
        )
    lines.extend(("", "## Routing", ""))
    for fixture, route in summary["fixture_routes"].items():
        lines.append(f"- `{fixture}` ({FIXTURES[fixture].parallelism}): **{route}**")
    lines.extend(("", "Default multi adoption requires no pass-rate loss, median speedup ≥1.20x, and no blinded quality regression. Per-fixture routing requires ≥1.15x and the same quality gate.", ""))
    report = "\n".join(lines)
    (experiment / "report.md").write_text(report)
    (experiment / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    return report


def run_rpc_probe(experiment: Path, phase: str) -> dict[str, Any]:
    """Record transport health without folding it into effectiveness metrics."""
    started = time.perf_counter()
    result = run_command((
        sys.executable, str(ROOT / "scripts/bench-agent.py"),
        "--rpc-only", "--mode", "pane", "--leader", "terminal",
        "--note", f"effectiveness {phase}",
    ), timeout=10 * 60)
    log = safe_failure(result.stdout + result.stderr)
    (experiment / f"rpc-{phase}.log").write_text(log + ("\n" if log else ""))
    return {
        "phase": phase, "exit_code": result.returncode,
        "duration_ms": round((time.perf_counter() - started) * 1000),
        "log": f"rpc-{phase}.log",
    }


def _run_experiment(args: argparse.Namespace) -> int:
    fixture_metadata = validate_fixture_metadata()
    fixtures = tuple(item for item in args.fixtures.split(",") if item)
    conditions = tuple(item for item in args.conditions.split(",") if item)
    unknown = set(fixtures) - set(FIXTURES)
    unknown_conditions = set(conditions) - set(CONDITIONS)
    if (
        unknown or unknown_conditions or not conditions or args.trials < 1 or args.workers != 3
        or args.timeout < 1 or args.infra_retries < 0
    ):
        raise ValueError(
            f"invalid fixtures={sorted(unknown)} conditions={sorted(unknown_conditions)} "
            f"trials={args.trials} workers={args.workers} "
            f"timeout={args.timeout} infra_retries={args.infra_retries}; workers must be 3"
        )
    specs = build_matrix(fixtures, args.trials, args.seed, conditions)
    print(f"effectiveness matrix: {len(specs)} runs")
    for index, spec in enumerate(specs, 1):
        print(f"  {index:02d}. {spec.fixture:<22} pair={spec.trial} order={spec.order} {spec.condition}")
    if args.dry_run:
        return 0
    if not shutil.which("claude") or not shutil.which("tm-agent"):
        raise RuntimeError("claude and tm-agent CLIs are required")
    run_id = args.run_id or datetime.now().strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:6]
    experiment = args.results_dir / run_id
    requested_manifest = {
        "schema": 1, "run_id": run_id, "created_at": utc_now(), "root_head": git("rev-parse", "HEAD"),
        "model": args.model, "effort": args.effort, "workers": args.workers, "trials": args.trials,
        "seed": args.seed, "timeout_seconds": args.timeout, "xcode_host": args.xcode_host,
        "infra_retries": args.infra_retries,
        "host": os.uname().nodename, "architecture": os.uname().machine,
        "claude_version": command_version("claude", "--version"),
        "tm_agent_version": command_version("tm-agent", "--version"),
        "fixtures": [row for row in fixture_metadata if row["fixture"] in fixtures],
        "matrix": [asdict(spec) for spec in specs],
    }
    if args.resume:
        if not experiment.is_dir():
            raise RuntimeError(f"cannot resume missing experiment: {experiment}")
        manifest, rows = load_experiment(experiment)
        errors = resume_manifest_errors(manifest, specs=specs, args=args)
        if errors:
            raise RuntimeError("resume manifest mismatch: " + "; ".join(errors))
    else:
        experiment.mkdir(parents=True, exist_ok=False)
        (experiment / "runs").mkdir()
        manifest = requested_manifest
        manifest_path = experiment / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
        manifest_path.chmod(0o444)
        rows = []
    rpc_probes: list[dict[str, Any]] = []
    if not args.skip_rpc_probe and not (args.resume and (experiment / "rpc-preflight.log").exists()):
        rpc_probes.append(run_rpc_probe(experiment, "preflight"))
    scratch = Path(tempfile.mkdtemp(prefix="term-mesh-effectiveness-"))
    completed = completed_spec_keys(rows)
    try:
        for index, spec in enumerate(specs, 1):
            if spec_key(spec) in completed:
                print(f"[{index}/{len(specs)}] {spec.fixture} {spec.condition} pair {spec.trial} SKIP completed", flush=True)
                continue
            for infra_attempt in range(args.infra_retries + 1):
                suffix = f" infra-retry {infra_attempt}/{args.infra_retries}" if infra_attempt else ""
                print(f"[{index}/{len(specs)}] {spec.fixture} {spec.condition} pair {spec.trial}{suffix}", flush=True)
                result = run_one(
                    spec, experiment=experiment, scratch=scratch, model=args.model, effort=args.effort,
                    timeout=args.timeout, xcode_host=args.xcode_host, keep_checkouts=args.keep_checkouts,
                )
                rows.append(asdict(result))
                if result.total_wall_ms is not None and not result.infra_invalid:
                    completed.add(spec_key(spec))
                print(f"  {result.status.upper()} {(result.total_wall_ms or 0) / 1000:.1f}s {result.failure_reason or ''}")
                summary = summarize(rows, seed=args.seed)
                render_report(experiment, manifest, rows, summary)
                if not result.infra_invalid or infra_attempt >= args.infra_retries:
                    break
    finally:
        if not args.keep_checkouts:
            shutil.rmtree(scratch, ignore_errors=True)
    if not args.skip_rpc_probe:
        rpc_probes.append(run_rpc_probe(experiment, "postflight"))
        (experiment / "rpc-probes.json").write_text(
            json.dumps({"schema": 1, "probes": rpc_probes}, indent=2, ensure_ascii=False) + "\n"
        )
    print(f"Saved: {experiment}")
    effective_rows = latest_effectiveness_rows(rows)
    return 0 if all(row["acceptance_passed"] for row in effective_rows) else 1


def run_experiment(args: argparse.Namespace) -> int:
    if args.dry_run:
        return _run_experiment(args)
    with benchmark_signal_cleanup(), benchmark_run_lock(args.results_dir):
        return _run_experiment(args)


def main() -> int:
    parser = argparse.ArgumentParser(description="Single-session vs 3-worker effectiveness benchmark")
    sub = parser.add_subparsers(dest="command", required=True)
    validate = sub.add_parser("validate-suite", help="prove baselines fail, oracle commits pass, and history is hidden")
    validate.add_argument("--output", type=Path, default=DEFAULT_RESULTS / "suite-validation")
    validate.add_argument("--xcode-host", default="mac-sub")
    validate.add_argument("--fixtures", default=",".join(FIXTURES))
    validate.add_argument("--keep-checkouts", action="store_true")
    run = sub.add_parser("run", help="run paired benchmark trials")
    run.add_argument("--suite", default="real-regressions", choices=("real-regressions",))
    run.add_argument("--fixtures", default=",".join(FIXTURES))
    run.add_argument("--conditions", default=",".join(CONDITIONS))
    run.add_argument("--workers", type=int, default=3)
    run.add_argument("--trials", type=int, default=3)
    run.add_argument("--seed", type=int, default=DEFAULT_SEED)
    run.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    run.add_argument("--infra-retries", type=int, default=DEFAULT_INFRA_RETRIES)
    run.add_argument("--model", default="sonnet")
    run.add_argument("--effort", default="medium", choices=("low", "medium", "high", "xhigh", "max"))
    run.add_argument("--xcode-host", default="mac-sub")
    run.add_argument("--results-dir", type=Path, default=DEFAULT_RESULTS)
    run.add_argument("--run-id")
    run.add_argument("--resume", action="store_true", help="continue an existing --run-id, skipping durable result cells")
    run.add_argument("--dry-run", action="store_true")
    run.add_argument("--keep-checkouts", action="store_true")
    run.add_argument("--skip-rpc-probe", action="store_true")
    report = sub.add_parser("report", help="regenerate metrics and optionally run blinded quality judges")
    report.add_argument("experiment", type=Path)
    report.add_argument("--evaluate", action="store_true")
    args = parser.parse_args()
    if args.command == "validate-suite":
        fixtures = tuple(item for item in args.fixtures.split(",") if item)
        unknown = set(fixtures) - set(FIXTURES)
        if unknown:
            parser.error(f"unknown fixtures: {sorted(unknown)}")
        result = validate_suite(
            output=args.output, xcode_host=args.xcode_host,
            keep_checkouts=args.keep_checkouts, fixtures=fixtures,
        )
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0 if result["passed"] else 1
    if args.command == "run":
        return run_experiment(args)
    experiment = args.experiment if args.experiment.is_dir() else args.experiment.parent
    manifest, rows = load_experiment(experiment)
    quality = evaluate_quality(experiment, rows, int(manifest["seed"])) if args.evaluate else None
    if quality is None and (experiment / "quality-eval.json").exists():
        quality = json.loads((experiment / "quality-eval.json").read_text())
    summary = summarize(rows, seed=int(manifest["seed"]), quality=quality)
    print(render_report(experiment, manifest, rows, summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
