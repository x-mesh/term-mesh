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
import itertools
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
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator, Optional, TextIO

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RESULTS = Path.home() / ".term-mesh" / "benchmarks" / "effectiveness"
DEFAULT_SEED = 20260814
DEFAULT_TIMEOUT = 45 * 60
DEFAULT_INFRA_RETRIES = 1
CONDITIONS = ("single", "multi")
ORCHESTRATION_CONDITIONS = ("single", "blocking", "overlap")
PARTITION_CONDITIONS = ("broad", "partitioned")
PARTITION_FIXTURES = ("split-divider-color",)
ISOLATED_TOPOLOGY_CONDITIONS = ("isolated-blocking", "isolated-overlap")
POLICIES = ("legacy", "adaptive")
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
    hidden_tests: tuple[tuple[str, str], ...] = ()


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
        oracle_files=(),
        hidden_tests=(
            (
                "termMeshTests/TerminalOverrideIsolationTests.swift",
                "tests/fixtures/effectiveness/split-divider-color/TerminalOverrideIsolationTests.swift.inc",
            ),
            (
                "termMeshTests/TermMeshWebViewKeyEquivalentTests.swift",
                "tests/fixtures/effectiveness/split-divider-color/TermMeshWebViewKeyEquivalentTests.swift.inc",
            ),
            (
                "Sources/TerminalWindowPortal.swift",
                "tests/fixtures/effectiveness/split-divider-color/TerminalWindowPortal.swift.inc",
            ),
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
    protocol_degraded: bool = False
    protocol_diagnostics: list[str] = field(default_factory=list)
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
    orchestration_schema: Optional[int] = None
    leader_preparation_ms: Optional[int] = None
    leader_first_result_review_ms: Optional[int] = None
    first_worker_result_ms: Optional[int] = None
    last_worker_result_ms: Optional[int] = None
    pure_worker_wait_ms: Optional[int] = None
    overlap_ms: Optional[int] = None
    read_overlap: Optional[dict[str, Any]] = None
    coordination_commands: dict[str, int] = field(default_factory=dict)
    routing_decision: Optional[str] = None
    routing_reason: Optional[str] = None
    routing_decision_ms: Optional[int] = None
    routing_tasks: list[dict[str, Any]] = field(default_factory=list)
    rework_count: int = 0
    tokens: dict[str, int] = field(default_factory=dict)
    token_precision: str = "actual"
    cost_usd: Optional[float] = None
    cost_precision: str = "unavailable"
    changed_files: int = 0
    cleanup_safe: bool = True
    cleanup_reason: Optional[str] = None
    paths: dict[str, str] = field(default_factory=dict)


class BenchmarkTerminated(RuntimeError):
    """Turn SIGTERM into normal stack unwinding so teams and scratch are cleaned."""


class BenchmarkInfrastructureError(RuntimeError):
    """Identify a controller prerequisite failure that invalidates a run."""


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
        for _, source in fixture.hidden_tests:
            if not (ROOT / source).is_file():
                raise RuntimeError(f"hidden acceptance source missing: {source}")
        rows.append({
            "fixture": fixture.name, "solution": solution, "base": parent,
            "oracle_files": list(fixture.oracle_files),
            "hidden_tests": [source for _, source in fixture.hidden_tests],
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


def build_orchestration_matrix(
    fixtures: Iterable[str], trials: int, seed: int,
    conditions: Iterable[str] = ORCHESTRATION_CONDITIONS,
) -> list[RunSpec]:
    """Build counterbalanced single/blocking/overlap trial blocks."""
    selected = tuple(conditions)
    specs: list[RunSpec] = []
    for fixture in fixtures:
        for trial in range(1, trials + 1):
            offset = (trial - 1) % len(ORCHESTRATION_CONDITIONS)
            order = list(ORCHESTRATION_CONDITIONS[offset:] + ORCHESTRATION_CONDITIONS[:offset])
            specs.extend(
                RunSpec(fixture, trial, condition, index)
                for index, condition in enumerate(order, 1)
                if condition in selected
            )
    return specs


def build_partition_matrix(
    fixtures: Iterable[str], trials: int, conditions: Iterable[str] = PARTITION_CONDITIONS,
) -> list[RunSpec]:
    """Build paired broad/partitioned trials with alternating order."""
    selected = tuple(conditions)
    specs: list[RunSpec] = []
    for fixture in fixtures:
        for trial in range(1, trials + 1):
            order = PARTITION_CONDITIONS if trial % 2 else tuple(reversed(PARTITION_CONDITIONS))
            specs.extend(
                RunSpec(fixture, trial, condition, index)
                for index, condition in enumerate(order, 1)
                if condition in selected
            )
    return specs


def build_isolated_topology_matrix(
    fixtures: Iterable[str], trials: int,
    conditions: Iterable[str] = ISOLATED_TOPOLOGY_CONDITIONS,
) -> list[RunSpec]:
    selected = tuple(conditions)
    specs = []
    for fixture in fixtures:
        for trial in range(1, trials + 1):
            order = ISOLATED_TOPOLOGY_CONDITIONS if trial % 2 else tuple(reversed(ISOLATED_TOPOLOGY_CONDITIONS))
            specs.extend(RunSpec(fixture, trial, condition, index) for index, condition in enumerate(order, 1) if condition in selected)
    return specs


def build_policy_matrix(
    fixtures: Iterable[str], trials: int, seed: int, policies: Iterable[str] = POLICIES,
) -> list[RunSpec]:
    """Build counterbalanced legacy/adaptive pairs without changing the old matrix."""
    rng = random.Random(seed)
    selected = tuple(policies)
    specs: list[RunSpec] = []
    for fixture in fixtures:
        for trial in range(1, trials + 1):
            if trial == 1:
                order = POLICIES
            elif trial == 2:
                order = tuple(reversed(POLICIES))
            else:
                order = POLICIES if rng.random() < 0.5 else tuple(reversed(POLICIES))
            specs.extend(
                RunSpec(fixture, trial, policy, index)
                for index, policy in enumerate(order, 1) if policy in selected
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


@contextlib.contextmanager
def hidden_test_overlay(fixture: Fixture, checkout: Path) -> Iterator[None]:
    backups: dict[str, bytes] = {}
    try:
        for target_relative, source_relative in fixture.hidden_tests:
            target = checkout / target_relative
            backups[target_relative] = target.read_bytes()
            source = (ROOT / source_relative).read_bytes()
            target.write_bytes(backups[target_relative] + source)
        yield
    finally:
        for target_relative, content in backups.items():
            (checkout / target_relative).write_bytes(content)


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


def xcode_failure_summary(output: str) -> str:
    diagnostics: list[str] = []
    patterns = (
        re.compile(r"^.*?:\d+:\d+: (?:error|warning): .+$"),
        re.compile(r"^.*?XCTAssert.* failed.*$"),
        re.compile(r"^Test Case '.*' failed.*$"),
    )
    for raw in output.splitlines():
        line = raw.strip()
        if any(pattern.match(line) for pattern in patterns) and line not in diagnostics:
            diagnostics.append(line)
    if diagnostics:
        return "\n".join(diagnostics[-20:])
    return output[-1200:].replace("\x00", "")


def run_divider_acceptance(
    checkout: Path, log: TextIO, timeout: float, xcode_host: str, run_id: str,
    *, build_info_generated: bool = False,
) -> tuple[bool, str]:
    tests = (
        "termMeshTests/HiddenSplitDividerBehaviorAcceptanceTests/testOverrideSerializationAndResetUseExistingSettingsBoundary",
        "termMeshTests/HiddenSplitDividerBehaviorAcceptanceTests/testParsedDividerColorReachesBonsplitAppearance",
        "termMeshTests/HiddenSplitDividerBehaviorAcceptanceTests/testExistingWorkspaceAppliesConfiguredColorAndResetImmediately",
        "termMeshTests/HiddenSplitDividerPortalAcceptanceTests/testOpaqueDividerRendersWithoutSurfaceOcclusion",
        "termMeshTests/HiddenSplitDividerPortalAcceptanceTests/testTranslucentDividerKeepsOcclusionPolicy",
    )
    source_packages = os.environ.get(
        "TERMMESH_BENCH_SOURCE_PACKAGES",
        "/Users/jinwoo/Library/Caches/term-mesh/SourcePackages",
    )
    derived_data = os.environ.get(
        "TERMMESH_BENCH_DERIVED_DATA",
        "/Users/jinwoo/Library/Developer/Xcode/DerivedData/term-mesh-effectiveness",
    )
    package_flags = [
        "-clonedSourcePackagesDirPath", source_packages,
        "-disableAutomaticPackageResolution",
        "-derivedDataPath", derived_data,
    ]
    command = [
        "xcodebuild", "-project", "GhosttyTabs.xcodeproj", "-scheme", "term-mesh-unit",
        "-configuration", "Debug", "-destination", "platform=macOS", *package_flags,
    ]
    for test in tests:
        command.extend(("-only-testing:" + test,))
    command.append("test")
    if xcode_host == "local":
        if not build_info_generated:
            generated = run_command(("bash", "scripts/generate-build-info.sh"), cwd=checkout, timeout=30)
            if generated.returncode != 0:
                return False, f"BuildInfo generation failed: {generated.stderr.strip()}"
        ok, reason = run_logged(tuple(command), checkout=checkout, log=log, timeout=timeout)
        if not ok:
            return ok, reason
        return run_logged(
            ("xcodebuild", "-project", "GhosttyTabs.xcodeproj", "-scheme", "term-mesh",
             "-configuration", "Debug", "-destination", "platform=macOS",
             *package_flags, "build"),
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
        build_info_step = "" if build_info_generated else " && ./scripts/generate-build-info.sh"
        remote_command = (
            "cd " + shlex.quote(remote)
            + " && ./scripts/check-ghostty-kit.sh"
            + build_info_step
            + " && " + shlex.join(command)
            + " && " + shlex.join((
            "xcodebuild", "-project", "GhosttyTabs.xcodeproj", "-scheme", "term-mesh",
            "-configuration", "Debug", "-destination", "platform=macOS",
            *package_flags, "build",
            ))
        )
        result = run_command(("ssh", xcode_host, remote_command), timeout=timeout)
        log.write(redact_text(result.stdout + result.stderr, checkout))
        return (
            result.returncode == 0,
            "passed" if result.returncode == 0
            else "remote Xcode acceptance failed:\n"
            + xcode_failure_summary(result.stdout + result.stderr),
        )
    finally:
        # The target is an exact, controller-created /tmp path.  Never expand a remote variable.
        run_command(("ssh", xcode_host, "rm", "-rf", remote), timeout=30)


def run_acceptance(
    fixture: Fixture, checkout: Path, log: TextIO, timeout: float, *,
    xcode_host: str, run_id: str, build_info_generated: bool = False,
) -> tuple[bool, int, str]:
    started = time.perf_counter()
    with oracle_overlay(fixture, checkout), hidden_test_overlay(fixture, checkout):
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
            passed, reason = run_divider_acceptance(
                checkout, log, timeout, xcode_host, run_id,
                build_info_generated=build_info_generated,
            )
    return passed, round((time.perf_counter() - started) * 1000), reason


class TraceWriter:
    def __init__(self, path: Path, session: str):
        self.path = path
        self.session = session
        self.sequence = 0
        self.lock = threading.Lock()

    def write(self, event_type: str, **fields: Any) -> None:
        with self.lock:
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
        "result": final.get("result") if isinstance(final.get("result"), str) else "",
    }


def stream_disallowed_read_only_tool_count(text: str) -> int:
    count = 0
    for line in text.splitlines():
        with contextlib.suppress(json.JSONDecodeError):
            event = json.loads(line)
            message = event.get("message") if isinstance(event.get("message"), dict) else {}
            content = message.get("content") if isinstance(message.get("content"), list) else []
            count += sum(
                isinstance(block, dict) and block.get("type") == "tool_use"
                and str(block.get("name", "")).lower() not in {"read", "grep", "glob"}
                for block in content
            )
    return count


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


def tm_agent_command_counts(text: str) -> dict[str, int]:
    """Count leader coordination commands from streamed shell tool calls."""
    counts = {name: 0 for name in (
        "delegate", "send", "wait", "collect", "read", "status",
        "finish_worktree", "isolated_delegate", "other",
    )}
    command_pattern = re.compile(
        r"(?:^|[\n;&|()])\s*(?:[^\s;&|()]*/)?tm-agent\s+"
        r"(delegate|send|wait|collect|read|status|task\s+finish-worktree|[a-z][\w-]*)\b",
        re.MULTILINE,
    )
    for line in text.splitlines():
        with contextlib.suppress(json.JSONDecodeError):
            event = json.loads(line)
            message = event.get("message", {})
            for block in message.get("content", []) if isinstance(message, dict) else []:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                payload = block.get("input", {})
                command = payload.get("command", "") if isinstance(payload, dict) else ""
                counts["isolated_delegate"] += len(re.findall(
                    r"tm-agent\s+delegate\b(?:(?![\n;&|]).)*--worktree\s+always\b",
                    command, re.MULTILINE,
                ))
                for match in command_pattern.finditer(command):
                    verb = match.group(1)
                    key = "finish_worktree" if verb == "task finish-worktree" else verb
                    counts[key if key in counts else "other"] += 1
    return counts


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


def create_benchmark_team(
    team: str, checkout: Path, model: str,
    agent_workdirs: Optional[dict[str, Path]] = None,
    timeout: float = 300,
) -> Any:
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
            **({"working_directory": str(agent_workdirs[role])} if agent_workdirs and role in agent_workdirs else {}),
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
        timeout=timeout,
    )


def create_isolated_worker_checkouts(
    checkout: Path, timeout: Callable[[], float] = lambda: 120.0,
) -> dict[str, Path]:
    workdirs = {}
    try:
        for role in ("explorer", "executor", "reviewer"):
            path = checkout.parent / f"{checkout.name}-worker-{role}"
            result = run_command(
                ("git", "worktree", "add", "--detach", str(path), "HEAD"),
                cwd=checkout, timeout=min(120, timeout()),
            )
            if result.returncode != 0:
                raise RuntimeError(f"worker worktree create failed for {role}: {result.stderr}")
            workdirs[role] = path
    except Exception:
        cleanup_isolated_worker_checkouts(checkout, workdirs)
        raise
    return workdirs


def integrate_worker_patches(
    checkout: Path, workdirs: dict[str, Path], tasks: list[dict[str, Any]],
    timeout: Callable[[], float] = lambda: 120.0,
) -> list[str]:
    integrated = []
    by_worker = {task["worker"]: task for task in tasks}
    leader_changed = set(git("diff", "--name-only", cwd=checkout).splitlines())
    leader_changed.update(git("ls-files", "--others", "--exclude-standard", cwd=checkout).splitlines())
    integration_order = [task["worker"] for task in tasks]
    if set(integration_order) != set(workdirs):
        raise RuntimeError("isolated integration workers do not match task workers")
    for role in integration_order:
        path = workdirs[role]
        tracked = set(git("diff", "--name-only", cwd=path).splitlines())
        untracked = set(git("ls-files", "--others", "--exclude-standard", cwd=path).splitlines())
        changed = tracked | untracked
        if not changed:
            continue
        allowed = set(by_worker[role]["owned"])
        outside = changed - allowed
        if outside:
            raise RuntimeError(f"isolated worker {role} changed forbidden paths: {sorted(outside)}")
        overlap = changed & leader_changed
        if overlap:
            raise RuntimeError(f"isolated integration ownership overlap: {sorted(overlap)}")
        if untracked:
            staged = run_command(("git", "add", "-N", "--", *sorted(untracked)), cwd=path, timeout=timeout())
            if staged.returncode != 0:
                raise RuntimeError(f"isolated integration could not expose untracked files: {staged.stderr}")
        patch = subprocess.run(
            ("git", "diff", "--binary"), cwd=path, capture_output=True, check=True,
            timeout=timeout(),
        ).stdout
        applied = subprocess.run(
            ("git", "apply", "--binary", "-"), cwd=checkout, input=patch, capture_output=True,
            timeout=timeout(),
        )
        if applied.returncode != 0:
            raise RuntimeError(f"isolated integration failed for {role}: {applied.stderr.decode(errors='replace')}")
        integrated.extend(sorted(changed))
        leader_changed.update(changed)
    return integrated


def default_worker_tasks() -> list[dict[str, Any]]:
    """The legacy fixed wave, represented in the structured v6 schema."""
    return [
        {
            "id": role, "worker": role, "goal": f"{role} 역할로 task를 완료",
            "owned": ["repository read surface" if role != "executor" else "required implementation files"],
            "forbidden": ["all repository writes" if role != "executor" else "unrelated files"],
            "depends_on": [], "verify": "task-specific verification",
            "mutates": role == "executor", "estimated_seconds": 300,
        }
        for role in ("explorer", "executor", "reviewer")
    ]


def partitioned_worker_tasks(fixture: Fixture) -> list[dict[str, Any]]:
    if fixture.name != "split-divider-color":
        raise ValueError(f"partitioned worker capsules are unavailable for {fixture.name}")
    return [
        {
            "id": "contract", "worker": "explorer",
            "strict_scope": True,
            "goal": "Report the Ghostty and Bonsplit divider contract from the listed paths",
            "owned": [
                "ghostty/src/config/Config.zig",
                "ghostty/macos/Sources/Features/Splits/SplitView.Divider.swift",
                "vendor/bonsplit/Sources/Bonsplit/Public/BonsplitConfiguration.swift",
                "vendor/bonsplit/Sources/Bonsplit/Internal/Styling/TabBarColors.swift",
                "vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitContainerView.swift",
            ],
            "forbidden": ["all other repository paths", "all repository writes"],
            "depends_on": [], "verify": "report path:line contract evidence",
            "mutates": False, "estimated_seconds": 300,
        },
        {
            "id": "implementation", "worker": "executor",
            "strict_scope": True,
            "goal": "Implement divider color, reset, runtime propagation, and focused unit tests",
            "owned": [
                "Sources/GhosttyConfig.swift", "Sources/SettingsView.swift",
                "Sources/TermMeshApp.swift", "Sources/TerminalSettings.swift",
                "Sources/TerminalWindowPortal.swift", "Sources/Workspace.swift",
                "Sources/WorkspaceContentView.swift", "termMeshTests/GhosttyConfigTests.swift",
                "termMeshTests/TerminalOverrideIsolationTests.swift",
            ],
            "forbidden": ["all other repository paths"],
            "depends_on": [], "verify": "run the focused settings and override unit tests",
            "mutates": True, "estimated_seconds": 300,
        },
        {
            "id": "acceptance", "worker": "reviewer",
            "strict_scope": True,
            "goal": "Build the divider acceptance matrix and report missing behavior",
            "owned": [
                "Makefile", "termMeshTests/GhosttyTerminalViewComposingTests.swift",
                "termMeshTests/TermMeshWebViewKeyEquivalentTests.swift",
            ],
            "forbidden": ["all other repository paths", "all repository writes"],
            "depends_on": [], "verify": "report requirement-to-test coverage and P0-P3 risks",
            "mutates": False, "estimated_seconds": 300,
        },
    ]


def isolated_topology_tasks(fixture: Fixture) -> list[dict[str, Any]]:
    if fixture.name != "split-divider-color":
        raise ValueError(f"isolated topology capsules are unavailable for {fixture.name}")
    tasks = [
        {
            "id": "settings", "worker": "executor", "strict_scope": True,
            "goal": "Implement divider settings, reset behavior, and focused override tests",
            "owned": [
                "Sources/SettingsView.swift",
                "Sources/TerminalSettings.swift",
                "termMeshTests/TerminalOverrideIsolationTests.swift",
            ],
            "forbidden": ["all other repository paths"],
            "depends_on": [], "verify": "run the focused override unit tests",
            "mutates": True, "estimated_seconds": 300,
        },
        {
            "id": "runtime", "worker": "explorer", "strict_scope": True,
            "goal": "Implement workspace runtime propagation and focused config tests",
            "owned": [
                "Sources/Workspace.swift",
                "termMeshTests/GhosttyConfigTests.swift",
            ],
            "forbidden": ["all other repository paths"],
            "depends_on": [], "verify": "run the focused config unit tests",
            "mutates": True, "estimated_seconds": 300,
        },
        {
            "id": "review", "worker": "reviewer", "strict_scope": True,
            "goal": "Review build and key-equivalent regression coverage",
            "owned": [
                "Makefile",
                "termMeshTests/TermMeshWebViewKeyEquivalentTests.swift",
            ],
            "forbidden": ["all other repository paths", "all repository writes"],
            "depends_on": [], "verify": "report requirement-to-test coverage and P0-P3 risks",
            "mutates": False, "estimated_seconds": 300,
        },
    ]
    for task in tasks:
        validate_worker_mutation_capability(task, allow_task_mutators=True)
    return tasks


def require_isolated_base_api(checkout: Path) -> None:
    """Fail before dispatch when the fixture lacks the required base API."""
    config = checkout / "Sources/GhosttyConfig.swift"
    if not config.is_file() or not re.search(
        r"\bvar\s+splitDividerColor\s*:\s*NSColor\?", config.read_text(),
    ):
        raise BenchmarkInfrastructureError(
            "isolated topology requires base GhosttyConfig.splitDividerColor API"
        )


ISOLATED_LEADER_OWNED = (
    "Sources/TerminalWindowPortal.swift",
    "termMeshTests/GhosttyTerminalViewComposingTests.swift",
)

SWIFT_ACTOR_TEST_CONTRACT = (
    "Any XCTest that directly calls Workspace, AppKit, or Bonsplit runtime APIs must declare "
    "@MainActor on the test type or method. A nonisolated XCTest may test only an existing "
    "nonisolated pure helper, such as Workspace.resolvedChromeColors."
)

SPLIT_DIVIDER_RUNTIME_CONTRACT = (
    "Keep the two split-divider behaviors independent. For Bonsplit appearance, set borderHex only "
    "from an explicit GhosttyConfig.splitDividerColor. A reset or unconfigured value must produce nil. "
    "Expose or reuse a pure helper for this mapping and add public tests for explicit, reset, and "
    "unconfigured inputs. For portal overlay rendering, use the actual resolved NSSplitView divider "
    "color regardless of its source. An opaque resolved color must always render the overlay without "
    "surface occlusion. A translucent resolved color must preserve the existing occlusion-only policy. "
    "Expose or reuse a separate pure helper for this decision and add public tests for opaque and "
    "translucent colors. Do not require a separate store or a specific architecture or wiring design. "
    "Do not inspect, infer, or disclose hidden acceptance test contents."
)

ISOLATED_LEADER_FOCUSED_TEST = (
    "xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh-unit "
    "-configuration Debug -destination platform=macOS "
    "-clonedSourcePackagesDirPath /Users/jinwoo/Library/Caches/term-mesh/SourcePackages "
    "-disableAutomaticPackageResolution "
    "-derivedDataPath /Users/jinwoo/Library/Developer/Xcode/DerivedData/term-mesh-effectiveness "
    "-only-testing:termMeshTests/WorkspaceChromeThemeTests "
    "-only-testing:termMeshTests/TerminalOverrideIsolationTests "
    "-only-testing:termMeshTests/GhosttyTerminalViewComposingTests test"
)

ISOLATED_LEADER_FORBIDDEN_VALIDATION_PATTERNS = (
    ("build-info", re.compile(r"(?:^|[;&|\n])\s*(?:bash\s+)?(?:\./)?scripts/generate-build-info\.sh\b")),
    ("xcodebuild-list", re.compile(r"\bxcodebuild\b[^\n;&|]*\s-list(?:\s|$)")),
    ("xcodebuild-resolve", re.compile(r"\bxcodebuild\b[^\n;&|]*-resolvePackageDependencies\b")),
    ("xcodebuild-build-for-testing", re.compile(r"\bxcodebuild\b[^\n;&|]*\bbuild-for-testing\b")),
    ("xcodebuild-test-without-building", re.compile(r"\bxcodebuild\b[^\n;&|]*\btest-without-building\b")),
    ("git-status", re.compile(r"(?:^|[;&|\n])\s*git\s+(?:-[A-Za-z]\s+\S+\s+)*status\b")),
    ("git-diff", re.compile(r"(?:^|[;&|\n])\s*git\s+(?:-[A-Za-z]\s+\S+\s+)*diff\b")),
    ("local-test", re.compile(
        r"(?:^|[;&|\n])\s*(?:swift\s+test|cargo\s+test|pytest\b|python(?:3)?\s+-m\s+(?:pytest|unittest)\b|"
        r"(?:\./)?scripts/(?:test|run-tests)[^\s;&|]*)"
    )),
)


def isolated_leader_prompt(fixture: Fixture, *, final: bool, worker_headers: str = "") -> str:
    phase = (
        "Worker patches are now integrated. Fix only your owned paths, then run exactly this command once: "
        + ISOLATED_LEADER_FOCUSED_TEST
        + " Do not discover schemes, resolve packages, retry the test, or run any other validation command."
        if final else
        "Workers are running in isolated checkouts. Implement the portal overlay behavior now. "
        "Do not validate in this phase. Do not run xcodebuild, local tests, xcodebuild -list, "
        "package resolution, build-for-testing, test-without-building, scripts/generate-build-info.sh, "
        "git status, or git diff."
    )
    return f"""
Actual isolated-worktree benchmark. {phase}
You own exactly: {json.dumps(ISOLATED_LEADER_OWNED)}. Do not read or modify any other repository path.
Opaque configured divider colors must render without surface occlusion. Existing translucent occlusion behavior must remain.
{SWIFT_ACTOR_TEST_CONTRACT}
{SPLIT_DIVIDER_RUNTIME_CONTRACT if fixture.name == "split-divider-color" else ""}
Do not use agents, tm-agent, background tasks, commits, pushes, releases, or external services.

TASK: {fixture.prompt}

WORKER RESULTS:
{worker_headers or 'pending'}
""".strip()


def stream_bash_commands(text: str) -> list[str]:
    commands: list[str] = []
    for line in text.splitlines():
        with contextlib.suppress(json.JSONDecodeError):
            event = json.loads(line)
            message = event.get("message") if isinstance(event.get("message"), dict) else {}
            content = message.get("content") if isinstance(message.get("content"), list) else []
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                if str(block.get("name", "")).lower() != "bash":
                    continue
                payload = block.get("input") if isinstance(block.get("input"), dict) else {}
                command = payload.get("command")
                if isinstance(command, str):
                    commands.append(command)
    return commands


def is_exact_isolated_leader_focused_test(command: str) -> bool:
    if command == ISOLATED_LEADER_FOCUSED_TEST:
        return True
    prefix = "cd "
    suffix = " && " + ISOLATED_LEADER_FOCUSED_TEST
    if not command.startswith(prefix) or not command.endswith(suffix):
        return False
    repo_path = command[len(prefix):-len(suffix)]
    if len(repo_path) >= 2 and repo_path[0] == repo_path[-1] and repo_path[0] in "'\"":
        return not any(character in repo_path[1:-1] for character in "$`\\")
    unsafe_unquoted = set(";&|*?[]{}~$`()<>\\'\"")
    return bool(repo_path) and not any(
        character.isspace() or character in unsafe_unquoted for character in repo_path
    )


def isolated_leader_validation_diagnostics(initial_stream: str, final_stream: str) -> list[str]:
    diagnostics: list[str] = []
    focused_total = 0
    for phase, stream in (("initial", initial_stream), ("final", final_stream)):
        for command in stream_bash_commands(stream):
            for name, pattern in ISOLATED_LEADER_FORBIDDEN_VALIDATION_PATTERNS:
                if pattern.search(command):
                    diagnostics.append(f"isolated leader {phase} used forbidden command: {name}")
            xcode_count = len(re.findall(r"(?:^|[;&|\n])\s*xcodebuild\b", command))
            if phase == "initial" and xcode_count:
                diagnostics.append("isolated leader initial used forbidden command: xcodebuild")
            if phase == "final":
                if is_exact_isolated_leader_focused_test(command):
                    focused_total += 1
                elif xcode_count or ISOLATED_LEADER_FOCUSED_TEST in command:
                    diagnostics.append("isolated leader final used non-focused xcodebuild command")
    if focused_total == 0:
        diagnostics.append("isolated leader focused test did not run")
    if focused_total > 1:
        diagnostics.append(f"isolated leader focused test ran {focused_total} times")
    return list(dict.fromkeys(diagnostics))


def validate_worker_mutation_capability(
    task: dict[str, Any], *, allow_task_mutators: bool = False,
) -> None:
    if task["mutates"] and task["worker"] != "executor" and not allow_task_mutators:
        raise ValueError(f"benchmark worker {task['worker']!r} is read-only")


def validate_routing_decision(
    payload: Any, *, available_workers: Iterable[str] = ("explorer", "executor", "reviewer"),
) -> tuple[str, str, list[dict[str, Any]]]:
    """Validate the Project policy v6 decision before any worker is dispatched."""
    if not isinstance(payload, dict):
        raise ValueError("decision must be a JSON object")
    route = payload.get("route")
    if route not in {"direct", "probe", "parallel"}:
        raise ValueError(f"invalid route {route!r}")
    reason = payload.get("reason")
    if not isinstance(reason, str) or not reason.strip():
        raise ValueError("reason must be a non-empty string")
    tasks = payload.get("tasks")
    if not isinstance(tasks, list):
        raise ValueError("tasks must be an array")
    expected = {"direct": (0, 0), "probe": (1, 1), "parallel": (2, 3)}[route]
    if not expected[0] <= len(tasks) <= expected[1]:
        raise ValueError(f"{route} requires {expected[0]}..{expected[1]} tasks, got {len(tasks)}")

    workers = set(available_workers)
    required_fields = (
        "id", "worker", "goal", "owned", "forbidden", "depends_on",
        "verify", "mutates", "estimated_seconds",
    )
    required = set(required_fields)
    normalized: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    seen_workers: set[str] = set()
    for index, task in enumerate(tasks):
        if not isinstance(task, dict) or not required.issubset(task):
            missing = sorted(required - set(task) if isinstance(task, dict) else required)
            raise ValueError(f"task {index} missing fields: {missing}")
        task_id = task["id"]
        worker = task["worker"]
        if not isinstance(task_id, str) or not task_id.strip() or task_id in seen_ids:
            raise ValueError(f"task {index} has invalid or duplicate id")
        if worker not in workers or worker in seen_workers:
            raise ValueError(f"task {index} has unavailable or duplicate worker {worker!r}")
        if not isinstance(task["goal"], str) or not task["goal"].strip():
            raise ValueError(f"task {index} goal must be non-empty")
        for field_name in ("owned", "forbidden", "depends_on"):
            value = task[field_name]
            if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
                raise ValueError(f"task {index} {field_name} must be a string array")
        if task["depends_on"]:
            raise ValueError(f"task {index} is not dependency-ready")
        if not isinstance(task["verify"], str) or not task["verify"].strip():
            raise ValueError(f"task {index} verify must be non-empty")
        if not isinstance(task["mutates"], bool):
            raise ValueError(f"task {index} mutates must be boolean")
        estimate = task["estimated_seconds"]
        if isinstance(estimate, bool) or not isinstance(estimate, int) or estimate <= 0:
            raise ValueError(f"task {index} estimated_seconds must be a positive integer")
        if route == "probe" and (task["mutates"] or not 60 <= estimate <= 90):
            raise ValueError("probe task must be read-only and estimated at 60..90 seconds")
        validate_worker_mutation_capability(task)
        seen_ids.add(task_id)
        seen_workers.add(worker)
        normalized.append({key: task[key] for key in required_fields})
    return route, reason.strip(), normalized


def worker_instruction(
    fixture: Fixture, team: str, role: str, task: Optional[dict[str, Any]] = None,
) -> str:
    result_file = f"/tmp/term-mesh-bench-{team}-{role}.result"
    report_file = f"~/.term-mesh/results/{team}/{role}-{uuid.uuid4().hex[:8]}-full.md"
    task = task or next(item for item in default_worker_tasks() if item["worker"] == role)
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
    if task["mutates"] and role != "executor":
        role_work = (
            "구현 담당이며 task의 owned 범위를 소유한다. 요구사항을 구현하고 관련 테스트를 "
            "추가하며 가능한 검증을 실행하라. commit은 만들지 마라."
        )
    mutation_rule = (
        "owned에 명시된 범위만 수정하고 forbidden 범위는 수정하지 마라."
        if task["mutates"] else "read-only task다. 어떤 repo 파일도 수정하지 마라."
    )
    read_rule = (
        "읽기와 검색도 owned에 나열된 exact path로 제한한다. forbidden 또는 다른 repository path를 읽지 마라."
        if task.get("strict_scope") else
        "역할 수행에 필요한 repository path를 읽고 검색할 수 있다."
    )
    return f"""
실제 개발 benchmark worker다. 현재 checkout만 사용하고 git history, benchmark controller, solution
commit, 외부 checkout에서 정답을 찾지 마라. 외부 remote에 push/publish/release하지 마라.

작업: {fixture.prompt}

역할: {role_work}
task id: {task['id']}
goal: {task['goal']}
owned: {json.dumps(task['owned'], ensure_ascii=False)}
forbidden: {json.dumps(task['forbidden'], ensure_ascii=False)}
verify: {task['verify']}
time budget: {task['estimated_seconds']} seconds
{mutation_rule}
{read_rule}
{SWIFT_ACTOR_TEST_CONTRACT if fixture.name == "split-divider-color" else ""}
{SPLIT_DIVIDER_RUNTIME_CONTRACT if fixture.name == "split-divider-color" else ""}
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
    tasks: Optional[list[dict[str, Any]]] = None,
) -> int:
    """Submit only the structured decision's tasks and verify each delivery."""
    env = tm_environment()
    selected = default_worker_tasks() if tasks is None else tasks
    if not selected:
        return 0
    roles = tuple(task["worker"] for task in selected)
    by_worker = {task["worker"]: task for task in selected}
    started = time.perf_counter()
    processes = {
        role: subprocess.Popen(
            (
                "tm-agent", "send", role, worker_instruction(fixture, team, role, by_worker[role]),
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
        "workers_dispatched", count=delivered, workers=list(roles),
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


def benchmark_team_directory(team: str) -> Optional[Path]:
    root = Path(os.environ.get("TERMMESH_HEADLESS_ROOT", Path.home() / ".term-mesh/headless"))
    for metadata in root.glob("*/team.json"):
        with contextlib.suppress(OSError, json.JSONDecodeError):
            if json.loads(metadata.read_text()).get("team_name") == team:
                return metadata.parent
    return None


def claude_session_path(session_id: str, checkout: Path) -> Optional[Path]:
    """Find one Claude transcript which belongs to this benchmark checkout."""
    root = Path.home() / ".claude/projects"
    expected = checkout.resolve(strict=False)
    for candidate in root.glob(f"**/{session_id}.jsonl"):
        with contextlib.suppress(OSError):
            scanned = 0
            with candidate.open(errors="replace") as handle:
                for line in handle:
                    scanned += len(line)
                    with contextlib.suppress(json.JSONDecodeError):
                        cwd = json.loads(line).get("cwd")
                        if isinstance(cwd, str) and Path(cwd).resolve(strict=False) == expected:
                            return candidate
                    if scanned >= 128 * 1024:
                        break
    return None


def normalize_benchmark_path(
    value: Any, checkout: Path, *, base: Optional[Path] = None,
) -> Optional[str]:
    if not isinstance(value, str) or not value:
        return None
    path = Path(value)
    if not path.is_absolute():
        path = (base or checkout) / path
    try:
        relative = path.resolve(strict=False).relative_to(checkout.resolve(strict=False))
    except ValueError:
        return None
    normalized = str(relative)
    return None if normalized in {"", "."} or normalized.startswith(".git/") else normalized


SHELL_READ_COMMANDS = {"cat", "sed", "head", "tail", "grep", "rg", "find", "ls", "wc"}
SHELL_OPTION_VALUES = {
    "sed": {"-e", "--expression", "-f", "--file"},
    "head": {"-n", "--lines", "-c", "--bytes"},
    "tail": {"-n", "--lines", "-c", "--bytes", "-s", "--sleep-interval", "--pid"},
    "grep": {"-e", "--regexp", "-f", "--file", "-m", "--max-count", "-A", "-B", "-C", "--after-context", "--before-context", "--context", "--exclude", "--include", "--exclude-dir"},
    "rg": {"-e", "--regexp", "-f", "--file", "-g", "--glob", "-t", "--type", "-T", "--type-not", "-A", "-B", "-C", "--after-context", "--before-context", "--context", "-m", "--max-count"},
    "ls": {"--block-size", "--color", "--format", "--hide", "--ignore", "--quoting-style", "--time", "--time-style"},
    "wc": {"--files0-from"},
}


def unsupported_shell_read_structure(command: str) -> bool:
    """Return true when shell syntax can hide repository file reads."""
    lowered = command.lower()
    segment_prefix = r"(?:^|[;&|]\s*)"
    dynamic_command = re.compile(
        segment_prefix + r"(?:xargs|(?:g|m)?awk|source|\.)\b",
        re.MULTILINE,
    )
    if dynamic_command.search(lowered):
        return True

    inline_interpreter = re.compile(
        segment_prefix + r"(?:python(?:3(?:\.\d+)*)?|perl|ruby)\b[^\n;&|]*\s(?:-c|-e)\s",
        re.MULTILINE,
    )
    file_api = re.compile(
        r"\b(?:open|read_text|read_bytes|readlines?|file\.(?:read|open|foreach)|io\.read)\s*\("
    )
    if inline_interpreter.search(lowered) and file_api.search(lowered):
        return True

    read_command = re.compile(
        r"(?:^|[;&|`(]\s*)(?:cat|sed|head|tail|grep|rg|find|ls|wc|xargs|(?:g|m)?awk|source|\.)\b",
        re.MULTILINE,
    )
    loop = re.search(r"\b(?:for|while)\b[\s\S]*?\bdo\b[\s\S]*?\bdone\b", lowered)
    loop_read_command = re.compile(
        r"\b(?:cat|sed|head|tail|grep|rg|find|ls|wc|xargs|(?:g|m)?awk|source)\b|(?:^|[;&|]\s*)\.\s"
    )
    if loop and (loop_read_command.search(loop.group(0)) or re.search(r"(?:^|[^<])<(?![<>&])", loop.group(0))):
        return True

    substitutions = re.findall(r"\$\(([^)]*)\)|`([^`]*)`", command, flags=re.DOTALL)
    return any(read_command.search(left or right) for left, right in substitutions)


def shell_read_operands(command: str, checkout: Path) -> tuple[list[str], list[str], int]:
    """Return concrete paths, glob patterns, and unresolved variable operands."""
    if unsupported_shell_read_structure(command):
        return [], [], 1
    command = re.sub(r"\\\n", " ", command).replace("\n", " ; ")
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|<>")
    lexer.whitespace_split = True
    lexer.commenters = "#"
    tokens = list(lexer)
    segments: list[list[str]] = []
    current: list[str] = []
    for token in tokens:
        if token in {";", "&&", "||", "|", "&"}:
            if current:
                segments.append(current)
                current = []
        else:
            current.append(token)
    if current:
        segments.append(current)

    concrete: list[str] = []
    patterns: list[str] = []
    unresolved = 0
    base = checkout.resolve(strict=False)
    assignment = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

    for raw_words in segments:
        words: list[str] = []
        skip_redirect = False
        for word in raw_words:
            if skip_redirect:
                skip_redirect = False
                continue
            if word in {"<", "<<", "<<<", ">", ">>", "<>", "<>&", ">&"}:
                skip_redirect = True
                continue
            if re.fullmatch(r"\d+", word) and not words:
                continue
            words.append(word)
        while words and assignment.match(words[0]):
            words.pop(0)
        if not words:
            continue
        command_name = Path(words.pop(0)).name
        if command_name == "cd":
            target = next((word for word in words if not word.startswith("-")), None)
            if target is None:
                continue
            if "$" in target:
                unresolved += 1
                continue
            normalized = normalize_benchmark_path(target, checkout, base=base)
            if normalized:
                base = (checkout / normalized).resolve(strict=False)
            elif target == ".":
                pass
            else:
                unresolved += 1
            continue
        if command_name not in SHELL_READ_COMMANDS:
            continue

        if command_name == "find":
            positionals = list(itertools.takewhile(
                lambda word: not word.startswith("-") and word not in {"!", "(", ")"}, words,
            ))
            words = []
        else:
            positionals = []
        option_supplied_pattern = False
        option_values = SHELL_OPTION_VALUES.get(command_name, set())
        index = 0
        while index < len(words):
            word = words[index]
            if word == "--":
                positionals.extend(words[index + 1:])
                break
            option = word.split("=", 1)[0]
            if word.startswith("-") and word != "-":
                takes_value = option in option_values
                if command_name in {"sed", "grep", "rg"} and option in {"-e", "--expression", "--regexp", "-f", "--file"}:
                    option_supplied_pattern = True
                if takes_value and "=" not in word and index + 1 < len(words):
                    index += 1
                index += 1
                continue
            positionals.append(word)
            index += 1

        if command_name == "sed" and positionals and not option_supplied_pattern:
            positionals = positionals[1:]
        elif command_name in {"grep", "rg"} and positionals and not option_supplied_pattern:
            positionals = positionals[1:]

        for operand in positionals:
            candidate = operand.rstrip(":,;")
            if not candidate or candidate == "-" or candidate.isdigit():
                continue
            if "$" in candidate or "`" in candidate or candidate.startswith("~"):
                unresolved += 1
                continue
            normalized = normalize_benchmark_path(candidate, checkout, base=base)
            if not normalized:
                continue
            if any(mark in candidate for mark in "*?["):
                patterns.append(normalized)
            else:
                concrete.append(normalized)
    return concrete, patterns, unresolved


def claude_read_paths(transcript: Path, checkout: Path) -> dict[str, Any]:
    """Extract repo-local read paths without treating shell syntax as file access."""
    reads: list[str] = []
    searches: list[str] = []
    path_patterns: list[str] = []
    write_paths: list[str] = []
    rows = malformed = tool_calls = unknown_tools = 0
    unresolved_paths = unresolved_shell_paths = write_path_unresolved = 0
    path_calls = extracted_path_calls = 0
    with transcript.open(errors="replace") as handle:
        for line in handle:
            rows += 1
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                malformed += 1
                continue
            if event.get("type") != "assistant":
                continue
            message = event.get("message") if isinstance(event.get("message"), dict) else {}
            content = message.get("content") if isinstance(message.get("content"), list) else []
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                tool_calls += 1
                name = str(block.get("name", "")).lower()
                payload = block.get("input") if isinstance(block.get("input"), dict) else {}
                if name == "read":
                    path_calls += 1
                    normalized = normalize_benchmark_path(payload.get("file_path"), checkout)
                    if normalized:
                        reads.append(normalized)
                        extracted_path_calls += 1
                    else:
                        unresolved_paths += 1
                elif name in {"grep", "glob"}:
                    path_calls += 1
                    normalized = normalize_benchmark_path(payload.get("path", "."), checkout)
                    if normalized:
                        searches.append(normalized)
                        extracted_path_calls += 1
                    else:
                        unresolved_paths += 1
                elif name == "bash":
                    command = payload.get("command")
                    if isinstance(command, str):
                        try:
                            concrete, patterns, shell_unresolved = shell_read_operands(command, checkout)
                        except ValueError:
                            unresolved_paths += 1
                            continue
                        searches.extend(concrete)
                        path_patterns.extend(patterns)
                        unresolved_shell_paths += shell_unresolved
                        path_calls += len(concrete) + len(patterns) + shell_unresolved
                        extracted_path_calls += len(concrete)
                    else:
                        path_calls += 1
                        unresolved_paths += 1
                elif name in {"edit", "write"}:
                    normalized = normalize_benchmark_path(payload.get("file_path"), checkout)
                    if normalized:
                        write_paths.append(normalized)
                    else:
                        write_path_unresolved += 1
                else:
                    unknown_tools += 1
    distinct = sorted(set(reads + searches))
    coverage_complete = (
        malformed == 0 and unknown_tools == 0 and unresolved_paths == 0
        and unresolved_shell_paths == 0 and not path_patterns
    )
    return {
        "status": "measured" if coverage_complete else "censored",
        "reason": None if coverage_complete else "incomplete transcript path coverage",
        "confidence": "high" if coverage_complete else "partial",
        "rows": rows, "malformed_rows": malformed, "tool_calls": tool_calls,
        "unknown_tool_calls": unknown_tools, "path_calls": path_calls,
        "extracted_path_calls": extracted_path_calls, "unresolved_path_calls": unresolved_paths,
        "unresolved_shell_paths": unresolved_shell_paths,
        "path_patterns": sorted(set(path_patterns)),
        "write_paths": sorted(set(write_paths)),
        "write_path_unresolved": write_path_unresolved,
        "path_extraction_coverage": (round(extracted_path_calls / path_calls, 3) if path_calls else 1.0),
        "read_calls": len(reads), "search_calls": len(searches),
        "distinct_reads": sorted(set(reads)), "distinct_search_roots": sorted(set(searches)),
        "distinct_access_paths": distinct,
        "repeated_accesses": len(reads) + len(searches) - len(distinct),
    }


def validate_access_scope(access: dict[str, Any], allowed: Iterable[str], owner: str) -> None:
    observed = set(access.get("distinct_access_paths", []))
    outside = {path for path in observed if path not in set(allowed)}
    if outside:
        raise RuntimeError(f"{owner} read outside owned scope: {sorted(outside)}")


def access_scope_extras(access: dict[str, Any], allowed: Iterable[str]) -> list[str]:
    return sorted(set(access.get("distinct_access_paths", [])) - set(allowed))


def benchmark_read_overlap(team: str, checkout: Path) -> dict[str, Any]:
    team_dir = benchmark_team_directory(team)
    if team_dir is None:
        return {"status": "unknown", "reason": "team metadata unavailable", "roles": {}}
    roles: dict[str, Any] = {}
    for metadata in sorted((team_dir / "agents").glob("*.json")):
        with contextlib.suppress(OSError, json.JSONDecodeError):
            payload = json.loads(metadata.read_text())
            role = str(payload.get("name") or metadata.stem)
            session_id = payload.get("session_id")
            agent_checkout = Path(payload.get("working_directory") or checkout)
            transcript = claude_session_path(session_id, agent_checkout) if isinstance(session_id, str) else None
            roles[role] = (
                claude_read_paths(transcript, agent_checkout) if transcript else
                {"status": "unknown", "reason": "transcript unavailable"}
            )
    complete = len(roles) == 3 and all(row.get("status") == "measured" for row in roles.values())
    if not complete:
        return {"status": "censored", "reason": "incomplete transcript coverage", "roles": roles}
    sets = {role: set(row["distinct_access_paths"]) for role, row in roles.items()}
    pairwise = {}
    for left, right in itertools.combinations(sorted(sets), 2):
        union = sets[left] | sets[right]
        pairwise[f"{left}:{right}"] = None if not union else round(len(sets[left] & sets[right]) / len(union), 3)
    common = sorted(set.intersection(*sets.values())) if sets else []
    return {"status": "measured", "roles": roles, "pairwise_jaccard": pairwise, "all_role_reads": common}


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
controller가 explorer, executor, reviewer 세 worker를 이미 동시에 dispatch하고 첫 결과 뒤 bounded settle window까지 기다렸다.
explorer와 reviewer는 read-only이고 executor만 구현 파일을 소유한다. 아래 worker envelope를 참고하고
필요할 때만 그 안의 FULL_REPORT를 읽어 통합·수정·최종 검증하라. 누락 worker를 다시 기다리거나
result 파일을 재조회하지 말고 leader가 직접 남은 일을 끝내라. 어떤 `tm-agent` 명령도 호출하지 마라.
`Monitor`, background task, `ToolSearch`, mem-mesh, `delegate`, `task`도 사용하지 마라. 세 worker는 이
checkout을 공유한다. 통합과 최종 검증은 leader가 책임진다.

worker envelopes:
{headers}
""".strip()
    return protocol + "\n\n" + common


def orchestration_preparation_prompt(fixture: Fixture) -> str:
    return f"""
실제 개발 benchmark의 준비 단계다. worker가 동시에 작업 중이다. 현재 checkout에서 요구사항,
관련 계약, 영향 경계, 기존 검증 명령만 읽어 통합 체크리스트를 작성하라. 파일을 만들거나
수정하지 말고 git 상태도 바꾸지 마라. agent, background task, tm-agent 명령은 사용하지 마라.

작업: {fixture.prompt}
""".strip()


def orchestration_review_prompt(fixture: Fixture, headers: str) -> str:
    return f"""
실제 개발 benchmark의 read-only 검토 단계다. 먼저 도착한 worker envelope만 검토하고 최종 통합
체크리스트를 보완하라. 파일을 만들거나 수정하지 말고 git 상태도 바꾸지 마라. 아직 도착하지
않은 worker를 기다리거나 조회하지 마라. agent, background task, tm-agent 명령은 사용하지 마라.

작업: {fixture.prompt}

준비된 worker envelope:
{headers or 'none'}
""".strip()


def orchestration_integration_prompt(
    fixture: Fixture, worker_headers: str, preparation: str, first_review: str,
) -> str:
    return f"""
실제 개발 benchmark의 최종 통합 단계다. worker 실행은 끝났다. 아래 준비 메모와 worker envelope를
사용하여 working tree를 통합·수정하고 관련 테스트와 가능한 검증을 실행하라. 아직 도착하지 않은
worker를 기다리거나 조회하지 마라. agent, background task, tm-agent 명령은 사용하지 마라. commit,
push, publish, release 및 외부 서비스 변경은 금지한다. 현재 checkout과 보이는 정보만 사용하라.

작업: {fixture.prompt}

리더 준비 메모:
{preparation or 'none'}

첫 결과 검토 메모:
{first_review or 'none'}

worker envelopes:
{worker_headers}
""".strip()


LEGACY_POLICY = """
## DELEGATE-FIRST PRINCIPLE
You are a coordinator, not a worker. For substantive reading, analysis, implementation, debugging,
review, and verification, delegate to the Project workers before doing the work yourself. Prefer
parallel delegation whenever possible. If a worker is idle and pending work exists, assign it.
Request controller delegation, consume every returned result, then integrate and validate.
Shared-checkout edits must have explicit disjoint ownership or run sequentially.
""".strip()

ADAPTIVE_POLICY = """
## TEAM-AWARE EXECUTION PRINCIPLE — POLICY V10
You are the coordinator and integration owner. Because the Project roster has available workers,
start each non-trivial request by decomposing it into independently completable units and assign
eligible units before doing that work in the leader lane. Prefer a two- or three-worker parallel wave
when at least two units are dependency-ready, independently verifiable, ownership-disjoint, and large
enough that dispatch and integration do not clearly dominate the work. Keep a distinct leader lane for
coordination, acceptance checks, integration, or unowned work. Direct execution is the explicit
exception for trivial, same-file, dependency-serial, or worker-ineligible work; record the concrete
constraint. Never manufacture work solely to occupy an idle worker. For admitted work request one
controller-managed wave with explicit ownership and independent verification. Use one dispatch, one
independent work interval, and one bounded result collection; use follow-ups only for blockers or
ownership expansion. Review, integrate, and validate the final result.
""".strip()


def policy_leader_prompt(fixture: Fixture, policy: str, decision_file: Path) -> str:
    if policy not in POLICIES:
        raise ValueError(f"unknown policy: {policy}")
    instructions = LEGACY_POLICY if policy == "legacy" else ADAPTIVE_POLICY
    return f"""
실제 Project leader policy A/B benchmark다. explorer, executor, reviewer worker가 이미 idle 상태로
Project에 존재한다. 오직 아래 POLICY에 따라 직접 실행할지 위임할지 판단하라. 현재 checkout만
사용하고 `tm-agent`, Agent/Task/Monitor 같은 별도 agent 도구는 호출하지 마라. controller가 worker
전달과 결과 수집을 대행한다. 최소한의 source context를 확인한 뒤 `{decision_file}`에 아래 schema의
JSON을 atomic하게 기록하라. direct이면 tasks는 빈 배열이다. probe이면 read-only task 정확히 1개와
60~90초 estimate를, parallel이면 dependency-ready task 2~3개를 기록하라. worker는 explorer, executor,
reviewer 중 겹치지 않게 선택한다. probe/parallel이면 repo를 수정하지 말고 decision 파일 기록 직후 turn을
끝내라. controller가 worker 결과를 전달하면 같은 session에서 통합과 최종 검증을 수행한다.
commit, push, publish, release 및 외부 서비스 변경은 금지한다. release script 테스트는 local bare repository와 stub
command만 사용하는 hermetic test여야 한다. solution commit, git history, benchmark controller, 다른
checkout에서 정답을 찾지 마라.

ROUTING JSON SCHEMA:
{{
  "route": "direct|probe|parallel",
  "reason": "...",
  "tasks": [{{
    "id": "stable-task-id", "worker": "explorer|executor|reviewer",
    "goal": "self-contained outcome", "owned": ["path or subsystem"],
    "forbidden": ["path or subsystem"], "depends_on": [],
    "verify": "one command", "mutates": false, "estimated_seconds": 90
  }}]
}}

POLICY:
{instructions}

TASK:
{fixture.prompt}

working tree에서 구현과 관련 테스트, 가능한 검증까지 완료하라.
""".strip()


def wait_for_worker_results(
    result_files: list[Path], *, timeout: float, trace: Optional[TraceWriter] = None,
    estimated_seconds: Optional[dict[Path, int]] = None, estimate_grace: float = 120.0,
    ready_times: Optional[dict[Path, int]] = None,
    cancel_event: Optional[threading.Event] = None,
    respect_estimates: bool = True,
) -> tuple[str, int, int]:
    """Wait for every result until its estimate or the shared timeout expires."""
    started = time.perf_counter()
    deadline = started + max(0, timeout)
    worker_deadlines = {
        path: (
            min(
                deadline,
                started + max(0, (estimated_seconds or {}).get(path, 0))
                + max(0, estimate_grace),
            )
            if respect_estimates else deadline
        )
        for path in result_files
    }
    while time.perf_counter() < deadline:
        if cancel_event is not None and cancel_event.is_set():
            break
        ready_now = {
            path for path in result_files
            if path.is_file() and path.stat().st_size > 0
        }
        if ready_times is not None:
            elapsed = round((time.perf_counter() - started) * 1000)
            for path in ready_now:
                ready_times.setdefault(path, elapsed)
        if len(ready_now) == len(result_files):
            break
        now = time.perf_counter()
        pending = [path for path in result_files if path not in ready_now]
        if pending and all(now >= worker_deadlines[path] for path in pending):
            break
        next_deadline = min(
            [deadline] + [worker_deadlines[path] for path in pending]
        )
        delay = min(0.25, max(0, next_deadline - now))
        if cancel_event is not None:
            cancel_event.wait(delay)
        else:
            time.sleep(delay)
    elapsed_ms = round((time.perf_counter() - started) * 1000)
    if ready_times is not None:
        for path in result_files:
            if path.is_file() and path.stat().st_size > 0:
                ready_times.setdefault(path, elapsed_ms)
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


def worker_result_headers(result_files: Iterable[Path]) -> tuple[str, int]:
    """Read the bounded worker envelopes which are available now."""
    sections = []
    ready = 0
    for path in result_files:
        if not path.is_file() or path.stat().st_size == 0:
            continue
        ready += 1
        sections.append(f"=== {path.name} ===\n" + "\n".join(
            path.read_text(errors="replace").splitlines()[:8]
        ))
    return "\n".join(sections), ready


def interval_overlap_ms(
    left_start: float, left_end: float, right_start: float, right_end: float,
) -> int:
    return round(max(0.0, min(left_end, right_end) - max(left_start, right_start)) * 1000)


def require_time_remaining(deadline: float, timeout: int) -> float:
    value = deadline - time.perf_counter()
    if value <= 0:
        raise TimeoutError(f"end-to-end timeout after {timeout}s")
    return value


def wait_for_first_worker_result(
    result_files: list[Path], *, timeout: float, trace: Optional[TraceWriter] = None,
) -> tuple[str, int, int]:
    """Wait only until one result is ready, then return every ready envelope."""
    started = time.perf_counter()
    deadline = started + max(0, timeout)
    headers, ready = worker_result_headers(result_files)
    while not ready and time.perf_counter() < deadline:
        time.sleep(min(0.25, max(0, deadline - time.perf_counter())))
        headers, ready = worker_result_headers(result_files)
    elapsed_ms = round((time.perf_counter() - started) * 1000)
    if trace is not None:
        trace.write("first_worker_result", ready=ready, expected=len(result_files), duration_ms=elapsed_ms)
    return headers, elapsed_ms, ready


def claude_command(
    prompt: str, *, model: str, effort: str, session_id: str, resume: bool, condition: str,
    tool_free: bool = False,
) -> list[str]:
    command = [
        "claude", "-p", prompt, "--output-format", "stream-json", "--verbose",
        "--model", model, "--effort", effort, "--permission-mode", "bypassPermissions",
        "--dangerously-skip-permissions", "--safe-mode", "--disable-slash-commands",
        "--strict-mcp-config",
        "--mcp-config", '{"mcpServers":{}}',
    ]
    command.extend(("--resume", session_id) if resume else ("--session-id", session_id))
    if tool_free:
        command.extend(("--tools", "Read,Grep,Glob"))
    disallowed = (
        "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Agent,Task,Monitor,ToolSearch"
        if tool_free else
        "Agent,Task" if condition == "single" else "Agent,Task,Monitor,ToolSearch"
    )
    command.extend(("--disallowedTools", disallowed))
    return command


def safe_failure(reason: str) -> str:
    return redact_text(reason)[-1800:]


def acceptance_failure_fingerprint(reason: str) -> str:
    """Identify the failing check while ignoring per-run paths and build ids."""
    normalized = redact_text(reason)
    normalized = re.sub(r"/tmp/term-mesh-effectiveness-[^/\s:'\"]+", "<checkout>", normalized)
    normalized = re.sub(
        r"<HOME>/Library/Developer/Xcode/DerivedData/[^/\s]+",
        "<derived-data>",
        normalized,
    )
    normalized = re.sub(r":\d+:\d+(?=:)", ":<line>:<column>", normalized)
    normalized = re.sub(r"\s+", " ", normalized).strip()
    return hashlib.sha256(normalized.encode()).hexdigest()[:16]


def note_acceptance_failure(reason: str, seen: set[str]) -> tuple[str, bool]:
    fingerprint = acceptance_failure_fingerprint(reason)
    repeated = fingerprint in seen
    seen.add(fingerprint)
    return fingerprint, repeated


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
        r"remote Xcode runner unavailable|CoreSimulator.*out[- ]of[- ]date|"
        r"DVTCoreSimulatorAdditionsErrorDomain|Unable to load simulator devices|"
        r"snapshot setup failed|submodule failed|daemon.*unavailable|"
        r"team not found|socket.*(?:missing|unavailable|refused)|"
        r"BenchmarkTerminated|benchmark interrupted by signal",
        reason, re.IGNORECASE,
    ))


def write_patch(checkout: Path, destination: Path) -> int:
    intent = run_command(("git", "add", "-N", "--all"), cwd=checkout, timeout=60)
    if intent.returncode != 0:
        raise RuntimeError(intent.stderr.strip() or "git add -N failed")
    patch = subprocess.run(
        ("git", "diff", "--binary", "--no-ext-diff", "--"),
        cwd=checkout, capture_output=True, timeout=60, check=False,
    )
    if patch.returncode != 0:
        raise RuntimeError(patch.stderr.decode(errors="replace").strip() or "git diff failed")
    destination.write_bytes(patch.stdout)
    names = git("diff", "--name-only", cwd=checkout)
    return len([line for line in names.splitlines() if line])


def add_protocol_diagnostic(record: RunResult, message: str) -> None:
    record.protocol_degraded = True
    diagnostic = safe_failure(message)
    if diagnostic not in record.protocol_diagnostics:
        record.protocol_diagnostics.append(diagnostic)


def collect_isolated_read_diagnostics(
    record: RunResult, *, team: str, checkout: Path, tasks: list[dict[str, Any]],
    session_id: str,
) -> None:
    try:
        record.read_overlap = benchmark_read_overlap(team, checkout)
    except Exception as error:
        record.read_overlap = {"status": "unavailable", "roles": {}}
        add_protocol_diagnostic(record, f"read-overlap telemetry unavailable: {type(error).__name__}: {error}")
        return

    if record.read_overlap.get("status") != "measured":
        add_protocol_diagnostic(record, "read-overlap coverage incomplete")

    try:
        by_worker = {task["worker"]: task for task in tasks}
        scope_extras = {}
        for role, access in record.read_overlap.get("roles", {}).items():
            task = by_worker.get(role)
            if task is None:
                add_protocol_diagnostic(record, f"read-overlap telemetry has unknown role: {role}")
                continue
            scope_extras[role] = access_scope_extras(access, task["owned"])

        leader_transcript = claude_session_path(session_id, checkout)
        if leader_transcript is None:
            add_protocol_diagnostic(record, "isolated leader transcript unavailable")
        else:
            leader_access = claude_read_paths(leader_transcript, checkout)
            scope_extras["leader"] = access_scope_extras(leader_access, ISOLATED_LEADER_OWNED)
            if leader_access.get("status") != "measured":
                add_protocol_diagnostic(record, "isolated leader read coverage incomplete")
        record.read_overlap["scope_extras"] = scope_extras
    except Exception as error:
        add_protocol_diagnostic(
            record, f"read-overlap diagnostic analysis failed: {type(error).__name__}: {error}",
        )


def checkout_content_digest(checkout: Path, excluded: Iterable[str]) -> dict[str, str]:
    excluded_set = set(excluded)
    files = run_command(("git", "ls-files", "-co", "--exclude-standard"), cwd=checkout, timeout=60)
    if files.returncode != 0:
        raise RuntimeError(files.stderr or "git ls-files failed")
    digest = {}
    for relative in files.stdout.splitlines():
        if relative in excluded_set:
            continue
        path = checkout / relative
        if path.is_file():
            digest[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return digest


def cleanup_isolated_worker_checkouts(checkout: Path, workdirs: dict[str, Path]) -> None:
    for path in workdirs.values():
        run_command(("git", "worktree", "remove", "--force", str(path)), cwd=checkout, timeout=120)
    run_command(("git", "worktree", "prune"), cwd=checkout, timeout=60)


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
                estimated_seconds={
                    path: task["estimated_seconds"]
                    for path, task in zip(result_files, default_worker_tasks())
                },
            )
            record.worker_active_critical_path_ms = worker_wait_ms
        else:
            worker_headers = None
        active_started = time.perf_counter()
        prompt = leader_prompt(fixture, spec.condition, team, worker_headers)
        with (experiment / paths["stdout"]).open("w") as stdout_log, (experiment / paths["acceptance"]).open("w") as acceptance_log:
            resume = False
            acceptance_failures: set[str] = set()
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
                if classify_infra_failure(record.failure_reason):
                    record.infra_invalid = True
                    record.status = "infra_invalid"
                    break
                fingerprint, repeated = note_acceptance_failure(
                    record.failure_reason, acceptance_failures
                )
                trace.write(
                    "acceptance_failure", attempt=record.correction_count + 1,
                    fingerprint=fingerprint, repeated=repeated,
                )
                if repeated:
                    trace.write(
                        "correction_skipped", reason="repeated_acceptance_failure",
                        fingerprint=fingerprint,
                    )
                    record.failure_reason = (
                        f"repeated acceptance failure ({fingerprint}); correction stopped: "
                        + record.failure_reason
                    )
                    break
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
            record.infra_invalid = record.infra_invalid or classify_infra_failure(
                record.failure_reason or ""
            )
            record.status = (
                "infra_invalid" if record.infra_invalid
                else "timeout" if record.timed_out
                else "failed"
            )
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


def run_orchestration_one(
    spec: RunSpec, *, experiment: Path, scratch: Path, model: str, effort: str,
    timeout: int, xcode_host: str, keep_checkouts: bool,
    worker_tasks: Optional[list[dict[str, Any]]] = None,
) -> RunResult:
    """Run one single, blocking, or overlapping orchestration cell."""
    if spec.condition == "single":
        result = run_one(
            RunSpec(spec.fixture, spec.trial, "single", spec.order),
            experiment=experiment, scratch=scratch, model=model, effort=effort, timeout=timeout,
            xcode_host=xcode_host, keep_checkouts=keep_checkouts,
        )
        result.condition = "single"
        result.orchestration_schema = 1
        (experiment / result.paths["result"]).write_text(
            json.dumps(asdict(result), indent=2, ensure_ascii=False) + "\n"
        )
        return result

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
        condition=spec.condition, order=spec.order, started_at=utc_now(), orchestration_schema=1,
        tokens={key: 0 for key in TOKEN_KEYS}, paths=paths,
    )
    trace = TraceWriter(experiment / paths["trace"], run_id)
    team: Optional[str] = None
    result_files: list[Path] = []
    guard_root: Optional[Path] = None
    total_started: Optional[float] = None
    worker_thread: Optional[threading.Thread] = None
    worker_box: dict[str, Any] = {}
    leader_checkout: Optional[Path] = None
    collector_cancel = threading.Event()
    try:
        create_snapshot(fixture, checkout)
        if spec.condition == "overlap":
            leader_checkout = scratch / f"{run_id}-leader-lane"
            create_snapshot(fixture, leader_checkout)
        agent_env, guard_root = benchmark_agent_environment(checkout)
        preparation_session_id = str(uuid.uuid4())
        integration_session_id = str(uuid.uuid4())
        total_started = time.perf_counter()
        trace.write("session_start", condition=spec.condition, fixture=fixture.name, model=model, effort=effort)
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
        selected_tasks = worker_tasks or default_worker_tasks()
        record.worker_tasks = dispatch_benchmark_workers(
            fixture, team, checkout, trace, timeout=min(timeout, 120), tasks=selected_tasks,
        )
        remaining = timeout - (time.perf_counter() - total_started)
        wait_timeout = min(15 * 60, max(0, remaining))
        estimates = {
            path: wait_timeout
            for path, task in zip(result_files, selected_tasks)
        }
        ready_times: dict[Path, int] = {}
        preparation = first_review = ""

        if spec.condition == "blocking":
            worker_headers, waited_ms, worker_ready = wait_for_worker_results(
                result_files, timeout=wait_timeout, trace=trace, estimated_seconds=estimates,
                ready_times=ready_times,
            )
            record.worker_active_critical_path_ms = waited_ms
            record.first_worker_result_ms = min(ready_times.values()) if ready_times else None
            record.last_worker_result_ms = max(ready_times.values()) if ready_times else None
            record.pure_worker_wait_ms = waited_ms
            record.overlap_ms = 0
        else:
            def collect_workers() -> None:
                worker_box["started"] = time.perf_counter()
                try:
                    worker_box["value"] = wait_for_worker_results(
                        result_files, timeout=wait_timeout, trace=trace, estimated_seconds=estimates,
                        ready_times=ready_times, cancel_event=collector_cancel,
                    )
                except Exception as error:
                    worker_box["error"] = error
                finally:
                    worker_box["ended"] = time.perf_counter()

            worker_thread = threading.Thread(
                target=collect_workers, name=f"{run_id}-workers", daemon=True,
            )
            worker_thread.start()
            trace.write("leader_lane_start")
            assert leader_checkout is not None
            before = git("diff", "--binary", cwd=leader_checkout)
            with (experiment / paths["stdout"]).open("w") as stdout_log:
                preparation_started = time.perf_counter()
                completed, first_action, prep_ms = run_stream(
                    claude_command(
                        orchestration_preparation_prompt(fixture), model=model, effort=effort,
                        session_id=preparation_session_id, resume=False, condition="multi", tool_free=True,
                    ),
                    cwd=leader_checkout, timeout=max(1, remaining), log=stdout_log, trace=trace,
                    label="leader_preparation", env=agent_env,
                )
                parsed = parse_stream(completed.stdout)
                preparation = parsed["result"]
                add_tokens(record.tokens, parsed["tokens"])
                record.leader_turns += parsed["turns"]
                record.leader_preparation_ms = prep_ms
                record.time_to_first_action_ms = first_action
                if completed.returncode != 0:
                    raise RuntimeError(safe_failure(completed.stderr or "leader preparation failed"))
                if stream_disallowed_read_only_tool_count(completed.stdout):
                    raise RuntimeError("overlap protocol violation: preparation used a non-read-only tool")
                after = git("diff", "--binary", cwd=leader_checkout)
                if after != before:
                    raise RuntimeError("overlap protocol violation: preparation changed the checkout")
                preparation_ended = time.perf_counter()

                first_headers, _, first_ready = wait_for_first_worker_result(
                    result_files, timeout=max(0, wait_timeout - prep_ms / 1000), trace=trace,
                )
                record.first_worker_result_ms = (
                    min(ready_times.values()) if ready_times else
                    round((time.perf_counter() - float(worker_box["started"])) * 1000)
                )
                if first_ready:
                    before = git("diff", "--binary", cwd=leader_checkout)
                    review_started = time.perf_counter()
                    completed, _, review_ms = run_stream(
                        claude_command(
                            orchestration_review_prompt(fixture, first_headers), model=model, effort=effort,
                            session_id=preparation_session_id, resume=True, condition="multi", tool_free=True,
                        ),
                        cwd=leader_checkout, timeout=max(1, timeout - (time.perf_counter() - total_started)),
                        log=stdout_log, trace=trace, label="leader_first_result_review", env=agent_env,
                    )
                    parsed = parse_stream(completed.stdout)
                    first_review = parsed["result"]
                    add_tokens(record.tokens, parsed["tokens"])
                    record.leader_turns += parsed["turns"]
                    record.leader_first_result_review_ms = review_ms
                    if completed.returncode != 0:
                        raise RuntimeError(safe_failure(completed.stderr or "leader review failed"))
                    if stream_disallowed_read_only_tool_count(completed.stdout):
                        raise RuntimeError("overlap protocol violation: first-result review used a non-read-only tool")
                    if git("diff", "--binary", cwd=leader_checkout) != before:
                        raise RuntimeError("overlap protocol violation: first-result review changed the checkout")
                    review_ended = time.perf_counter()
            assert worker_thread is not None
            worker_thread.join(timeout=max(0, timeout - (time.perf_counter() - total_started)))
            if worker_thread.is_alive():
                raise RuntimeError("worker collection exceeded the orchestration deadline")
            if worker_box.get("error"):
                raise RuntimeError(f"worker collection failed: {worker_box['error']}")
            worker_headers, waited_ms, worker_ready = worker_box["value"]
            record.worker_active_critical_path_ms = waited_ms
            record.last_worker_result_ms = max(ready_times.values()) if ready_times else None
            lane_ms = (record.leader_preparation_ms or 0) + (record.leader_first_result_review_ms or 0)
            worker_started = float(worker_box["started"])
            worker_ended = float(worker_box["ended"])
            record.overlap_ms = interval_overlap_ms(
                worker_started, worker_ended, preparation_started, preparation_ended,
            ) + (
                interval_overlap_ms(worker_started, worker_ended, review_started, review_ended)
                if first_ready else 0
            )
            worker_interval_ms = round((worker_ended - worker_started) * 1000)
            record.pure_worker_wait_ms = max(0, worker_interval_ms - record.overlap_ms)
            trace.write(
                "leader_lane_end", duration_ms=lane_ms, overlap_ms=record.overlap_ms,
                pure_wait_ms=record.pure_worker_wait_ms,
            )
        if worker_ready != len(result_files):
            record.protocol_degraded = True
            record.failure_reason = f"protocol degraded: worker results {worker_ready}/{len(result_files)}"
            record.status = "failed"
            record.total_wall_ms = round((time.perf_counter() - total_started) * 1000)
            record.read_overlap = benchmark_read_overlap(team, checkout)
            record.changed_files = write_patch(checkout, experiment / paths["patch"])
            return record

        active_started = time.perf_counter()
        trace.write("integration_start")
        prompt = orchestration_integration_prompt(fixture, worker_headers, preparation, first_review)
        with (experiment / paths["stdout"]).open("a") as stdout_log, (experiment / paths["acceptance"]).open("w") as acceptance_log:
            acceptance_failures: set[str] = set()
            integration_resume = False
            while True:
                remaining = timeout - (time.perf_counter() - total_started)
                if remaining <= 0:
                    record.timed_out = True
                    record.failure_reason = f"end-to-end timeout after {timeout}s"
                    break
                completed, first_action, _ = run_stream(
                    claude_command(
                        prompt, model=model, effort=effort, session_id=integration_session_id,
                        resume=integration_resume, condition="multi",
                    ),
                    cwd=checkout, timeout=max(1, remaining), log=stdout_log, trace=trace,
                    label="correction" if integration_resume and record.correction_count else "integration",
                    env=agent_env,
                )
                parsed = parse_stream(completed.stdout)
                add_tokens(record.tokens, parsed["tokens"])
                record.leader_turns += parsed["turns"]
                if record.time_to_first_action_ms is None:
                    record.time_to_first_action_ms = first_action
                if completed.returncode != 0:
                    raise RuntimeError(safe_failure(completed.stderr or "leader integration failed"))
                remaining = timeout - (time.perf_counter() - total_started)
                trace.write("acceptance_start", attempt=record.correction_count + 1)
                passed, acceptance_ms, reason = run_acceptance(
                    fixture, checkout, acceptance_log, remaining, xcode_host=xcode_host, run_id=run_id,
                )
                record.acceptance_ms += acceptance_ms
                trace.write(
                    "acceptance_end", attempt=record.correction_count + 1, duration_ms=acceptance_ms,
                    status="passed" if passed else "failed",
                )
                if passed:
                    record.acceptance_passed = True
                    record.status = "passed"
                    record.failure_reason = None
                    break
                record.failure_reason = safe_failure(reason)
                if classify_infra_failure(record.failure_reason):
                    record.infra_invalid = True
                    record.status = "infra_invalid"
                    break
                fingerprint, repeated = note_acceptance_failure(record.failure_reason, acceptance_failures)
                if repeated:
                    record.failure_reason = f"repeated acceptance failure ({fingerprint}); correction stopped: {record.failure_reason}"
                    break
                record.correction_count += 1
                prompt = (
                    "숨은 acceptance가 실패했다. 같은 session에서 직접 수정하고 다시 검증하라. "
                    "worker를 다시 시작하지 마라. 실패 항목:\n" + record.failure_reason
                )
                integration_resume = True
        record.active_task_ms = round((time.perf_counter() - active_started) * 1000)
        record.total_wall_ms = round((time.perf_counter() - total_started) * 1000)
        record.read_overlap = benchmark_read_overlap(team, checkout)
        if record.read_overlap.get("status") != "measured":
            record.protocol_degraded = True
            record.failure_reason = (record.failure_reason + "; " if record.failure_reason else "") + (
                "protocol degraded: read-overlap coverage incomplete"
            )
        worker_tokens, _, observed, expected = team_usage(team, checkout)
        add_tokens(record.tokens, worker_tokens)
        record.token_precision = "actual_all" if observed == expected else (
            "leader_actual_workers_partial" if observed else "leader_actual_workers_unavailable"
        )
        record.cost_usd = estimate_cost(record.tokens, model)
        record.cost_precision = "token_estimate" if record.cost_usd is not None else "unavailable"
        record.changed_files = write_patch(checkout, experiment / paths["patch"])
        if record.status != "passed":
            record.status = "infra_invalid" if record.infra_invalid else (
                "timeout" if record.timed_out else "failed"
            )
    except Exception as error:
        record.failure_reason = safe_failure(f"{type(error).__name__}: {error}")
        record.infra_invalid = classify_infra_failure(record.failure_reason)
        record.status = "infra_invalid" if record.infra_invalid else "failed"
        if total_started is not None:
            record.total_wall_ms = round((time.perf_counter() - total_started) * 1000)
        with contextlib.suppress(Exception):
            if checkout.exists():
                record.changed_files = write_patch(checkout, experiment / paths["patch"])
    finally:
        cleanup_safe = True
        if worker_thread and worker_thread.is_alive():
            collector_cancel.set()
            worker_thread.join(timeout=2)
            if worker_thread.is_alive():
                cleanup_safe = False
                record.status = "failed"
                record.failure_reason = "worker collector did not stop before cleanup"
                record.total_wall_ms = None
        record.cleanup_safe = cleanup_safe
        record.cleanup_reason = None if cleanup_safe else record.failure_reason
        if cleanup_safe and team and checkout.exists():
            with contextlib.suppress(Exception):
                daemon_json("headless.destroy_team", {"team_name": team}, timeout=90)
        record.finished_at = utc_now()
        trace.write("session_end", status=record.status, total_wall_ms=record.total_wall_ms, tokens=record.tokens)
        (experiment / paths["result"]).write_text(json.dumps(asdict(record), indent=2, ensure_ascii=False) + "\n")
        if cleanup_safe and checkout.exists() and not keep_checkouts:
            shutil.rmtree(checkout, ignore_errors=True)
        if cleanup_safe and leader_checkout and leader_checkout.exists() and not keep_checkouts:
            shutil.rmtree(leader_checkout, ignore_errors=True)
        if cleanup_safe and guard_root is not None:
            shutil.rmtree(guard_root, ignore_errors=True)
        if cleanup_safe:
            for result_file in result_files:
                result_file.unlink(missing_ok=True)
    return record


def run_isolated_topology_one(
    spec: RunSpec, *, experiment: Path, scratch: Path, model: str, effort: str,
    timeout: int, xcode_host: str, keep_checkouts: bool,
) -> RunResult:
    fixture = FIXTURES[spec.fixture]
    run_id = f"{fixture.name}-{spec.condition}-t{spec.trial}-{uuid.uuid4().hex[:8]}"
    run_dir = experiment / "runs" / run_id
    run_dir.mkdir(parents=True)
    checkout = scratch / run_id
    relative = Path("runs") / run_id
    paths = {name: str(relative / filename) for name, filename in {
        "result": "result.json", "trace": "trace.jsonl", "patch": "candidate.patch",
        "stdout": "stdout.log", "acceptance": "acceptance.log",
    }.items()}
    record = RunResult(
        run_id=run_id, fixture=fixture.name, parallelism=fixture.parallelism, trial=spec.trial,
        condition=spec.condition, order=spec.order, started_at=utc_now(), orchestration_schema=2,
        tokens={key: 0 for key in TOKEN_KEYS}, paths=paths,
    )
    trace = TraceWriter(experiment / paths["trace"], run_id)
    team = None
    workdirs: dict[str, Path] = {}
    result_files: list[Path] = []
    guard_root = None
    worker_thread: Optional[threading.Thread] = None
    worker_box: dict[str, Any] = {}
    cancel = threading.Event()
    total_started = None
    deadline = None
    tasks = isolated_topology_tasks(fixture)
    initial_leader_stream = ""
    final_leader_stream = ""
    try:
        create_snapshot(fixture, checkout)
        require_isolated_base_api(checkout)
        total_started = time.perf_counter()
        deadline = total_started + timeout
        remaining = lambda: max(0.0, deadline - time.perf_counter())
        require_remaining = lambda: require_time_remaining(deadline, timeout)
        workdirs = create_isolated_worker_checkouts(checkout, timeout=require_remaining)
        agent_env, guard_root = benchmark_agent_environment(checkout)
        session_id = str(uuid.uuid4())
        trace.write("session_start", condition=spec.condition, fixture=fixture.name, topology="isolated")
        team = f"bench-isolated-{uuid.uuid4().hex[:8]}"
        result_files = [Path(f"/tmp/term-mesh-bench-{team}-{role}.result") for role in ("explorer", "executor", "reviewer")]
        create_benchmark_team(
            team, checkout, model, agent_workdirs=workdirs,
            timeout=min(300, require_remaining()),
        )
        record.worker_tasks = dispatch_benchmark_workers(
            fixture, team, checkout, trace, timeout=min(120, require_remaining()), tasks=tasks
        )
        ready_times: dict[Path, int] = {}

        def collect() -> None:
            worker_box["started"] = time.perf_counter()
            try:
                worker_box["value"] = wait_for_worker_results(
                    result_files, timeout=require_remaining(), trace=trace,
                    estimated_seconds={path: 15 * 60 for path in result_files},
                    ready_times=ready_times, cancel_event=cancel,
                    respect_estimates=False,
                )
            except Exception as error:
                worker_box["error"] = error
            finally:
                worker_box["ended"] = time.perf_counter()

        worker_thread = threading.Thread(target=collect, daemon=True)
        worker_thread.start()
        before_unowned = checkout_content_digest(checkout, ISOLATED_LEADER_OWNED)
        if spec.condition == "isolated-overlap":
            leader_started = time.perf_counter()
            with (experiment / paths["stdout"]).open("w") as log:
                completed, first_action, duration = run_stream(
                    claude_command(
                        isolated_leader_prompt(fixture, final=False), model=model, effort=effort,
                        session_id=session_id, resume=False, condition="multi",
                    ), cwd=checkout, timeout=require_remaining(), log=log, trace=trace,
                    label="leader_implementation", env=agent_env,
                )
            record.time_to_first_action_ms = first_action
            record.leader_preparation_ms = duration
            parsed = parse_stream(completed.stdout); add_tokens(record.tokens, parsed["tokens"]); record.leader_turns += parsed["turns"]
            initial_leader_stream = completed.stdout
            if completed.returncode != 0:
                raise RuntimeError(completed.stderr or "leader implementation failed")
            if checkout_content_digest(checkout, ISOLATED_LEADER_OWNED) != before_unowned:
                raise RuntimeError("leader modified paths outside isolated ownership")
            leader_ended = time.perf_counter()
        worker_thread.join(timeout=remaining())
        if worker_thread.is_alive():
            raise RuntimeError("isolated worker collection timed out")
        if worker_box.get("error"):
            raise RuntimeError(f"isolated worker collection failed: {worker_box['error']}")
        headers, waited_ms, ready = worker_box["value"]
        if ready != len(result_files):
            raise RuntimeError(f"isolated worker results {ready}/{len(result_files)}")
        record.worker_active_critical_path_ms = waited_ms
        record.first_worker_result_ms = min(ready_times.values())
        record.last_worker_result_ms = max(ready_times.values())
        if spec.condition == "isolated-overlap":
            record.overlap_ms = interval_overlap_ms(
                float(worker_box["started"]), float(worker_box["ended"]), leader_started, leader_ended
            )
            record.pure_worker_wait_ms = max(0, waited_ms - record.overlap_ms)
        else:
            record.overlap_ms = 0; record.pure_worker_wait_ms = waited_ms
            before_unowned = checkout_content_digest(checkout, ISOLATED_LEADER_OWNED)
            with (experiment / paths["stdout"]).open("w") as log:
                completed, first_action, duration = run_stream(
                    claude_command(
                        isolated_leader_prompt(fixture, final=False), model=model, effort=effort,
                        session_id=session_id, resume=False, condition="multi",
                    ), cwd=checkout, timeout=require_remaining(), log=log, trace=trace,
                    label="leader_implementation", env=agent_env,
                )
            record.time_to_first_action_ms = first_action; record.leader_preparation_ms = duration
            parsed = parse_stream(completed.stdout); add_tokens(record.tokens, parsed["tokens"]); record.leader_turns += parsed["turns"]
            initial_leader_stream = completed.stdout
            if completed.returncode != 0 or checkout_content_digest(checkout, ISOLATED_LEADER_OWNED) != before_unowned:
                raise RuntimeError("blocking leader violated isolated ownership or failed")
        integrated = integrate_worker_patches(checkout, workdirs, tasks, timeout=require_remaining)
        trace.write("worker_patches_integrated", files=integrated)
        generated = run_command(
            ("bash", "scripts/generate-build-info.sh"), cwd=checkout, timeout=min(30, require_remaining()),
        )
        trace.write("isolated_leader_build_info", status="passed" if generated.returncode == 0 else "failed")
        if generated.returncode != 0:
            raise BenchmarkInfrastructureError(
                "isolated leader BuildInfo generation failed: "
                + (generated.stderr.strip() or generated.stdout.strip() or "unknown error")
            )
        active_started = time.perf_counter()
        with (experiment / paths["stdout"]).open("a") as log, (experiment / paths["acceptance"]).open("w") as acceptance_log:
            completed, _, duration = run_stream(
                claude_command(
                    isolated_leader_prompt(fixture, final=True, worker_headers=headers), model=model, effort=effort,
                    session_id=session_id, resume=True, condition="multi",
                ), cwd=checkout, timeout=require_remaining(),
                log=log, trace=trace, label="integration_verification", env=agent_env,
            )
            record.leader_first_result_review_ms = duration
            parsed = parse_stream(completed.stdout); add_tokens(record.tokens, parsed["tokens"]); record.leader_turns += parsed["turns"]
            final_leader_stream = completed.stdout
            for diagnostic in isolated_leader_validation_diagnostics(
                initial_leader_stream, final_leader_stream,
            ):
                add_protocol_diagnostic(record, diagnostic)
            if completed.returncode != 0:
                raise RuntimeError(completed.stderr or "integration verification failed")
            passed, acceptance_ms, reason = run_acceptance(
                fixture, checkout, acceptance_log, require_remaining(),
                xcode_host=xcode_host, run_id=run_id, build_info_generated=True,
            )
            record.acceptance_ms = acceptance_ms; record.acceptance_passed = passed
            record.status = "passed" if passed else "failed"; record.failure_reason = None if passed else safe_failure(reason)
        record.active_task_ms = round((time.perf_counter() - active_started) * 1000)
        record.total_wall_ms = round((time.perf_counter() - total_started) * 1000)
        collect_isolated_read_diagnostics(
            record, team=team, checkout=checkout, tasks=tasks, session_id=session_id,
        )
        try:
            worker_tokens, _, observed, expected = team_usage(team, checkout)
            add_tokens(record.tokens, worker_tokens)
            record.token_precision = "actual_all" if observed == expected else "leader_actual_workers_partial"
            record.cost_usd = estimate_cost(record.tokens, model)
            record.cost_precision = "token_estimate"
        except Exception as error:
            record.token_precision = "leader_actual_workers_unavailable"
            record.cost_precision = "unavailable"
            add_protocol_diagnostic(
                record, f"worker usage telemetry unavailable: {type(error).__name__}: {error}",
            )
        try:
            record.changed_files = write_patch(checkout, experiment / paths["patch"])
        except Exception as error:
            add_protocol_diagnostic(
                record, f"candidate patch unavailable: {type(error).__name__}: {error}",
            )
    except Exception as error:
        record.failure_reason = safe_failure(f"{type(error).__name__}: {error}"); record.status = "failed"
        if isinstance(error, BenchmarkInfrastructureError):
            record.infra_invalid = True
            record.status = "infra_invalid"
        if total_started is not None: record.total_wall_ms = round((time.perf_counter() - total_started) * 1000)
        with contextlib.suppress(Exception): record.changed_files = write_patch(checkout, experiment / paths["patch"])
    finally:
        cancel.set()
        cleanup_safe = True
        if worker_thread and worker_thread.is_alive():
            worker_thread.join(timeout=2)
            cleanup_safe = not worker_thread.is_alive()
        record.cleanup_safe = cleanup_safe
        record.cleanup_reason = None if cleanup_safe else "worker collector did not stop before cleanup"
        if not cleanup_safe:
            record.status = "failed"
            record.failure_reason = record.cleanup_reason
            record.total_wall_ms = None
        if cleanup_safe and team:
            with contextlib.suppress(Exception): daemon_json("headless.destroy_team", {"team_name": team}, timeout=90)
        if cleanup_safe and workdirs and checkout.exists(): cleanup_isolated_worker_checkouts(checkout, workdirs)
        record.finished_at = utc_now(); trace.write("session_end", status=record.status, total_wall_ms=record.total_wall_ms, tokens=record.tokens)
        (experiment / paths["result"]).write_text(json.dumps(asdict(record), indent=2, ensure_ascii=False) + "\n")
        if cleanup_safe and checkout.exists() and not keep_checkouts: shutil.rmtree(checkout, ignore_errors=True)
        if cleanup_safe and guard_root is not None: shutil.rmtree(guard_root, ignore_errors=True)
        if cleanup_safe:
            for path in result_files: path.unlink(missing_ok=True)
    return record


def run_policy_one(
    spec: RunSpec, *, experiment: Path, scratch: Path, model: str, effort: str,
    timeout: int, xcode_host: str, keep_checkouts: bool,
) -> RunResult:
    """Run one Project with an idle worker pool; vary only the leader policy."""
    fixture = FIXTURES[spec.fixture]
    run_id = f"{fixture.name}-{spec.condition}-t{spec.trial}-{uuid.uuid4().hex[:8]}"
    run_dir = experiment / "runs" / run_id
    run_dir.mkdir(parents=True)
    checkout = scratch / run_id
    relative_run = Path("runs") / run_id
    paths = {
        "result": str(relative_run / "result.json"),
        "trace": str(relative_run / "trace.jsonl"),
        "patch": str(relative_run / "candidate.patch"),
        "stdout": str(relative_run / "stdout.log"),
        "acceptance": str(relative_run / "acceptance.log"),
        "decision": str(relative_run / "routing-decision.json"),
    }
    record = RunResult(
        run_id=run_id, fixture=fixture.name, parallelism=fixture.parallelism,
        trial=spec.trial, condition=spec.condition, order=spec.order, started_at=utc_now(),
        tokens={key: 0 for key in TOKEN_KEYS}, paths=paths,
    )
    trace = TraceWriter(experiment / paths["trace"], run_id)
    team: Optional[str] = None
    guard_root: Optional[Path] = None
    result_files: list[Path] = []
    total_started: Optional[float] = None
    try:
        create_snapshot(fixture, checkout)
        agent_env, guard_root = benchmark_agent_environment(checkout)
        session_id = str(uuid.uuid4())
        team = f"bench-policy-{uuid.uuid4().hex[:10]}"
        total_started = time.perf_counter()
        total_started_epoch = time.time()
        init_started = time.perf_counter()
        create_benchmark_team(team, checkout, model)
        record.team_init_ms = round((time.perf_counter() - init_started) * 1000)
        trace.write(
            "session_start", condition=spec.condition, fixture=fixture.name,
            model=model, effort=effort, team_init_ms=record.team_init_ms,
        )
        decision_file = experiment / paths["decision"]
        prompt = policy_leader_prompt(fixture, spec.condition, decision_file)
        active_started = time.perf_counter()
        with (experiment / paths["stdout"]).open("w") as stdout_log, (
            experiment / paths["acceptance"]
        ).open("w") as acceptance_log:
            resume = False
            routed = False
            acceptance_failures: set[str] = set()
            while True:
                remaining = timeout - (time.perf_counter() - total_started)
                if remaining <= 0:
                    record.timed_out = True
                    record.failure_reason = f"end-to-end timeout after {timeout}s"
                    break
                command = claude_command(
                    prompt, model=model, effort=effort, session_id=session_id,
                    resume=resume, condition="policy",
                )
                try:
                    completed, first_action, _ = run_stream(
                        command, cwd=checkout, timeout=remaining, log=stdout_log,
                        trace=trace, label="correction" if resume else "initial", env=agent_env,
                    )
                except subprocess.TimeoutExpired:
                    record.timed_out = True
                    record.failure_reason = f"leader timeout after {timeout}s"
                    break
                if record.time_to_first_action_ms is None:
                    record.time_to_first_action_ms = first_action
                parsed = parse_stream(completed.stdout)
                add_tokens(record.tokens, parsed["tokens"])
                record.leader_turns += parsed["turns"]
                if parsed["cost_usd"] is not None:
                    record.cost_usd = (record.cost_usd or 0.0) + float(parsed["cost_usd"])
                counts = tm_agent_command_counts(completed.stdout)
                for key, value in counts.items():
                    record.coordination_commands[key] = record.coordination_commands.get(key, 0) + value
                record.worker_tasks += counts["delegate"] + counts["send"]
                if completed.returncode != 0:
                    record.failure_reason = safe_failure(completed.stderr or f"leader exit {completed.returncode}")
                    break
                if not routed:
                    if not decision_file.is_file():
                        record.failure_reason = "policy protocol violation: routing decision file missing"
                        break
                    try:
                        decision = json.loads(decision_file.read_text())
                    except (OSError, json.JSONDecodeError) as error:
                        record.failure_reason = f"policy protocol violation: invalid routing decision: {error}"
                        break
                    try:
                        route, reason, routing_tasks = validate_routing_decision(decision)
                    except ValueError as error:
                        record.failure_reason = f"policy protocol violation: {error}"
                        break
                    record.routing_decision = route
                    record.routing_reason = reason[:1000]
                    record.routing_tasks = routing_tasks
                    record.routing_decision_ms = max(
                        0, round((decision_file.stat().st_mtime - total_started_epoch) * 1000),
                    )
                    trace.write(
                        "routing_decision", route=route, tasks=len(routing_tasks),
                        workers=[task["worker"] for task in routing_tasks],
                        duration_ms=record.routing_decision_ms,
                    )
                    routed = True
                    if route in {"probe", "parallel"}:
                        record.worker_tasks = dispatch_benchmark_workers(
                            fixture, team, checkout, trace, timeout=min(120, remaining),
                            tasks=routing_tasks,
                        )
                        result_files = [
                            Path(f"/tmp/term-mesh-bench-{team}-{task['worker']}.result")
                            for task in routing_tasks
                        ]
                        remaining = timeout - (time.perf_counter() - total_started)
                        estimate = max(task["estimated_seconds"] for task in routing_tasks)
                        wave_timeout = min(10 * 60, estimate + 60, max(0, remaining))
                        headers, wait_ms, ready = wait_for_worker_results(
                            result_files, timeout=wave_timeout, trace=trace,
                            estimated_seconds={
                                path: task["estimated_seconds"]
                                for path, task in zip(result_files, routing_tasks)
                            },
                        )
                        record.worker_active_critical_path_ms = wait_ms
                        record.coordination_commands["controller_dispatch"] = record.worker_tasks
                        record.coordination_commands["controller_collect"] = 1
                        prompt = f"""
controller가 선택한 {route} route에 따라 worker wave를 실행했다. ready={ready}/{len(routing_tasks)}. 아래 bounded
envelope와 필요한 FULL_REPORT만 읽어 구현을 통합·수정하고 최종 검증하라. worker를 다시 dispatch하거나
기다리지 말고 남은 일은 직접 완료하라.

{headers}
""".strip()
                        resume = True
                        continue
                remaining = timeout - (time.perf_counter() - total_started)
                if remaining <= 0:
                    record.timed_out = True
                    record.failure_reason = f"end-to-end timeout after {timeout}s"
                    break
                passed, acceptance_ms, reason = run_acceptance(
                    fixture, checkout, acceptance_log, remaining,
                    xcode_host=xcode_host, run_id=run_id,
                )
                record.acceptance_ms += acceptance_ms
                if passed:
                    record.acceptance_passed = True
                    record.status = "passed"
                    record.failure_reason = None
                    break
                record.failure_reason = safe_failure(reason)
                if classify_infra_failure(record.failure_reason):
                    record.infra_invalid = True
                    record.status = "infra_invalid"
                    break
                fingerprint, repeated = note_acceptance_failure(
                    record.failure_reason, acceptance_failures
                )
                trace.write(
                    "acceptance_failure", attempt=record.correction_count + 1,
                    fingerprint=fingerprint, repeated=repeated,
                )
                if repeated:
                    trace.write(
                        "correction_skipped", reason="repeated_acceptance_failure",
                        fingerprint=fingerprint,
                    )
                    record.failure_reason = (
                        f"repeated acceptance failure ({fingerprint}); correction stopped: "
                        + record.failure_reason
                    )
                    break
                record.correction_count += 1
                prompt = (
                    "숨은 acceptance가 실패했다. 같은 policy와 session을 유지하여 직접 수정하거나 "
                    "필요한 worker를 조정하고 다시 검증하라. 실패 항목:\n" + record.failure_reason
                )
                resume = True
        record.active_task_ms = round((time.perf_counter() - active_started) * 1000)
        record.total_wall_ms = round((time.perf_counter() - total_started) * 1000)
        selected_workers = [task["worker"] for task in record.routing_tasks]
        worker_tokens, _, observed, expected = team_usage(team, checkout, selected_workers)
        add_tokens(record.tokens, worker_tokens)
        worker_cost = estimate_cost(worker_tokens, model) if observed else None
        if worker_cost is not None:
            record.cost_usd = (record.cost_usd or 0.0) + worker_cost
        record.token_precision = "actual_all" if observed == expected else (
            "leader_actual_workers_partial" if observed else "leader_actual_workers_unavailable"
        )
        record.cost_precision = "leader_actual_workers_estimate" if observed == expected else record.token_precision
        if record.cost_usd is None:
            record.cost_usd = estimate_cost(record.tokens, model)
            if record.cost_usd is not None:
                record.cost_precision = "token_estimate"
        record.changed_files = write_patch(checkout, experiment / paths["patch"])
        if record.status != "passed":
            record.infra_invalid = record.infra_invalid or classify_infra_failure(record.failure_reason or "")
            record.status = "infra_invalid" if record.infra_invalid else (
                "timeout" if record.timed_out else "failed"
            )
    except Exception as error:
        record.failure_reason = safe_failure(f"{type(error).__name__}: {error}")
        record.infra_invalid = classify_infra_failure(record.failure_reason)
        record.status = "infra_invalid" if record.infra_invalid else "failed"
        if total_started is not None:
            record.total_wall_ms = round((time.perf_counter() - total_started) * 1000)
        with contextlib.suppress(Exception):
            if checkout.exists():
                record.changed_files = write_patch(checkout, experiment / paths["patch"])
    finally:
        if team and checkout.exists():
            with contextlib.suppress(Exception):
                daemon_json("headless.destroy_team", {"team_name": team}, timeout=90)
        record.finished_at = utc_now()
        trace.write(
            "session_end", status=record.status, total_wall_ms=record.total_wall_ms,
            tokens=record.tokens, coordination=record.coordination_commands,
        )
        (experiment / paths["result"]).write_text(
            json.dumps(asdict(record), indent=2, ensure_ascii=False) + "\n"
        )
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
            "outcome": (
                "both_success" if single.get("acceptance_passed") and multi.get("acceptance_passed")
                else "single_only" if single.get("acceptance_passed")
                else "multi_only" if multi.get("acceptance_passed")
                else "neither_success"
            ),
            "speedup": speedup,
            "token_amplification": (
                (multi_tokens / single_tokens) if valid_latency and single_tokens else None
            ),
            "cost_ratio": (
                (float(multi_cost) / float(single_cost))
                if valid_latency and single_cost and multi_cost is not None else None
            ),
            "single_run_id": single["run_id"], "multi_run_id": multi["run_id"],
        })
    return pairs


def orchestration_pair_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    usable = latest_effectiveness_rows(rows)
    grouped: dict[tuple[str, int], dict[str, dict[str, Any]]] = {}
    for row in usable:
        if not row.get("infra_invalid") and not row.get("protocol_degraded"):
            grouped.setdefault((row["fixture"], int(row["trial"])), {})[row["condition"]] = row
    pairs = []
    for (fixture, trial), conditions in sorted(grouped.items()):
        for baseline in ("single", "blocking"):
            if baseline not in conditions or "overlap" not in conditions:
                continue
            left, overlap = conditions[baseline], conditions["overlap"]
            both_passed = bool(left.get("acceptance_passed") and overlap.get("acceptance_passed"))
            speedup = None
            if both_passed and left.get("total_wall_ms") and overlap.get("total_wall_ms"):
                speedup = left["total_wall_ms"] / overlap["total_wall_ms"]
            pairs.append({
                "fixture": fixture, "trial": trial, "baseline": baseline,
                "baseline_passed": bool(left.get("acceptance_passed")),
                "overlap_passed": bool(overlap.get("acceptance_passed")),
                "speedup": speedup, "baseline_run_id": left["run_id"],
                "overlap_run_id": overlap["run_id"],
            })
    return pairs


def summarize_orchestration(
    rows: list[dict[str, Any]], *, seed: int, quality: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    usable = latest_effectiveness_rows(rows)
    conditions = {}
    for condition in ORCHESTRATION_CONDITIONS:
        selected = [row for row in usable if row["condition"] == condition]
        passed = [row for row in selected if row.get("acceptance_passed")]
        walls = [float(row["total_wall_ms"]) for row in passed if row.get("total_wall_ms") is not None]
        conditions[condition] = {
            "runs": len(selected), "passed": len(passed),
            "pass_rate": len(passed) / len(selected) if selected else None,
            "median_wall_ms": statistics.median(walls) if walls else None,
            "median_overlap_ms": statistics.median(
                row["overlap_ms"] for row in passed if row.get("overlap_ms") is not None
            ) if any(row.get("overlap_ms") is not None for row in passed) else None,
            "median_pure_wait_ms": statistics.median(
                row["pure_worker_wait_ms"] for row in passed if row.get("pure_worker_wait_ms") is not None
            ) if any(row.get("pure_worker_wait_ms") is not None for row in passed) else None,
        }
    pairs = orchestration_pair_rows(usable)
    comparisons = {}
    for baseline in ("single", "blocking"):
        selected = [row for row in pairs if row["baseline"] == baseline]
        speedups = [float(row["speedup"]) for row in selected if row["speedup"] is not None]
        comparisons[f"{baseline}_vs_overlap"] = {
            "pairs": len(selected), "latency_pairs": len(speedups),
            "median_speedup": statistics.median(speedups) if speedups else None,
            "bootstrap_95ci": bootstrap_ci(speedups, seed=seed),
        }
    complete = all(conditions[name]["runs"] >= len(FIXTURES) * 3 for name in ORCHESTRATION_CONDITIONS)
    no_pass_loss = all(
        conditions["overlap"]["pass_rate"] is not None
        and conditions[name]["pass_rate"] is not None
        and conditions["overlap"]["pass_rate"] >= conditions[name]["pass_rate"]
        for name in ("single", "blocking")
    )
    speed = comparisons["single_vs_overlap"]["median_speedup"]
    quality_rows = quality.get("comparisons", []) if quality else []
    quality_keys = {(row.get("fixture"), int(row.get("trial", 0))) for row in quality_rows}
    expected_quality_keys = {(fixture, trial) for fixture in FIXTURES for trial in range(1, 4)}
    quality_ready = len(quality_rows) == len(expected_quality_keys) and quality_keys == expected_quality_keys and all(
        int(row.get("valid_judges", 0)) >= 3 and row.get("overlap_regression") is not None
        for row in quality_rows
    )
    quality_regression = any(row.get("overlap_regression") is True for row in quality_rows)
    expected_pairs = len(FIXTURES) * 3
    complete_latency_pairs = all(
        comparisons[name]["latency_pairs"] == expected_pairs
        for name in ("single_vs_overlap", "blocking_vs_overlap")
    )
    latency_gate_ready = bool(
        complete and complete_latency_pairs and no_pass_loss and speed is not None and speed >= 1.20
    )
    return {
        "conditions": conditions, "pairs": pairs, "comparisons": comparisons,
        "complete_experiment": complete, "no_pass_rate_loss": no_pass_loss,
        "complete_latency_pairs": complete_latency_pairs,
        "quality_ready": quality_ready,
        "quality_regression": quality_regression if quality_ready else None,
        "promotion_ready": bool(latency_gate_ready and quality_ready and not quality_regression),
        "latency_gate_ready": latency_gate_ready,
        "usable_runs": len(usable), "attempt_runs": len(rows),
        "protocol_degraded_runs": sum(bool(row.get("protocol_degraded")) for row in usable),
    }


def summarize_partition(rows: list[dict[str, Any]], *, seed: int) -> dict[str, Any]:
    usable = latest_effectiveness_rows(rows)
    conditions = {}
    for condition in PARTITION_CONDITIONS:
        selected = [row for row in usable if row["condition"] == condition]
        passed = [row for row in selected if row.get("acceptance_passed") and not row.get("protocol_degraded")]
        walls = [float(row["total_wall_ms"]) for row in passed if row.get("total_wall_ms") is not None]
        critical = [float(row["worker_active_critical_path_ms"]) for row in passed if row.get("worker_active_critical_path_ms") is not None]
        conditions[condition] = {
            "runs": len(selected), "passed": len(passed),
            "pass_rate": len(passed) / len(selected) if selected else None,
            "median_wall_ms": statistics.median(walls) if walls else None,
            "median_worker_critical_ms": statistics.median(critical) if critical else None,
        }
    grouped = {}
    for row in usable:
        if not row.get("infra_invalid") and not row.get("protocol_degraded"):
            grouped.setdefault((row["fixture"], int(row["trial"])), {})[row["condition"]] = row
    pairs = []
    for (fixture, trial), pair in sorted(grouped.items()):
        if set(pair) != set(PARTITION_CONDITIONS):
            continue
        broad, partitioned = pair["broad"], pair["partitioned"]
        both_passed = bool(broad.get("acceptance_passed") and partitioned.get("acceptance_passed"))
        speedup = None
        if both_passed and broad.get("total_wall_ms") and partitioned.get("total_wall_ms"):
            speedup = broad["total_wall_ms"] / partitioned["total_wall_ms"]
        pairs.append({"fixture": fixture, "trial": trial, "speedup": speedup})
    speedups = [float(pair["speedup"]) for pair in pairs if pair["speedup"] is not None]
    return {
        "conditions": conditions, "pairs": pairs,
        "median_speedup": statistics.median(speedups) if speedups else None,
        "bootstrap_95ci": bootstrap_ci(speedups, seed=seed),
        "latency_pairs": len(speedups), "usable_runs": len(usable),
        "protocol_degraded_runs": sum(bool(row.get("protocol_degraded")) for row in usable),
    }


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
    successful_pairs = [pair for pair in pairs if pair["single_passed"] and pair["multi_passed"]]
    token_amps = [
        float(pair["token_amplification"]) for pair in successful_pairs
        if pair["token_amplification"] is not None
    ]
    cost_ratios = [
        float(pair["cost_ratio"]) for pair in successful_pairs
        if pair["cost_ratio"] is not None
    ]
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
    fixture_evidence: dict[str, Any] = {}
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
        fixture_evidence[fixture] = {
            "pairs": len(all_fixture_pairs),
            "latency_pairs": len(latency_pairs),
            "censored_pairs": sum(pair["outcome"] == "neither_success" for pair in all_fixture_pairs),
            "single_only_pairs": sum(pair["outcome"] == "single_only" for pair in all_fixture_pairs),
            "multi_only_pairs": sum(pair["outcome"] == "multi_only" for pair in all_fixture_pairs),
            "both_success_pairs": sum(pair["outcome"] == "both_success" for pair in all_fixture_pairs),
        }
        if not enough_evidence or (single_passes == 0 and multi_passes == 0):
            routes[fixture] = "insufficient_evidence"
        elif single_passes == 0 < multi_passes:
            routes[fixture] = "multi"
        elif multi_passes == 0 < single_passes:
            routes[fixture] = "single"
        elif (
            values and statistics.median(values) >= 1.15
            and no_regression and multi_passes >= single_passes
        ):
            routes[fixture] = "multi"
        else:
            routes[fixture] = "single"
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
        "fixture_evidence": fixture_evidence,
        "latency_pairs": len(speedups),
        "censored_pairs": sum(pair["outcome"] == "neither_success" for pair in pairs),
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


def evaluate_orchestration_quality(
    experiment: Path, rows: list[dict[str, Any]], seed: int,
) -> dict[str, Any]:
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
    rng = random.Random(seed)
    comparisons = []
    eval_dir = experiment / "quality"
    eval_dir.mkdir(exist_ok=True)
    for pair in orchestration_pair_rows(rows):
        if pair["baseline"] != "single" or not (pair["baseline_passed"] and pair["overlap_passed"]):
            continue
        patches = {
            "single": (experiment / by_id[pair["baseline_run_id"]]["paths"]["patch"]).read_text(),
            "overlap": (experiment / by_id[pair["overlap_run_id"]]["paths"]["patch"]).read_text(),
        }
        results = []
        first_order = ["single", "overlap"] if rng.random() < 0.5 else ["overlap", "single"]
        for index, vendor in enumerate(judges):
            order = first_order if index % 2 == 0 else list(reversed(first_order))
            prompt_path = eval_dir / f"{pair['fixture']}-t{pair['trial']}-j{index + 1}.txt"
            prompt_path.write_text(
                quality_prompt(FIXTURES[pair["fixture"]], patches[order[0]], patches[order[1]])
            )
            judged = run_command((
                "xm", "panel", "cross", "--models", vendor, "--prompt-file", str(prompt_path),
                "--json", "--source", "eval:judge",
                "--title", f"orchestration {pair['fixture']} t{pair['trial']}",
            ), timeout=20 * 60)
            raw = judged.stdout
            with contextlib.suppress(Exception):
                payload = json.loads(raw)
                raw = payload.get("results", [{}])[0].get("output", raw)
            if judged.returncode != 0:
                results.append({"vendor": vendor, "ok": False, "error": safe_failure(judged.stderr)})
                continue
            parsed = parse_judge_output(raw)
            scores = {condition: parsed[label] for label, condition in zip(("A", "B"), order)}
            winner = parsed["winner"]
            mapped = "tie" if winner == "tie" else order[0 if winner == "A" else 1]
            results.append({"vendor": vendor, "ok": True, "order": order, "winner": mapped, "scores": scores})
        good = [result for result in results if result.get("ok")]
        def total(condition: str) -> float:
            scores = [statistics.mean(float(value) for value in row["scores"][condition].values()) for row in good]
            return statistics.mean(scores) if scores else 0.0
        single_score, overlap_score = total("single"), total("overlap")
        comparisons.append({
            "fixture": pair["fixture"], "trial": pair["trial"], "judges": results,
            "single_score": single_score, "overlap_score": overlap_score,
            "valid_judges": len(good),
            "overlap_regression": (overlap_score + 0.25 < single_score) if len(good) >= 3 else None,
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
        f"Latency-comparable pairs: {summary['latency_pairs']} / {len(summary['pairs'])} "
        f"(both-failed/censored {summary['censored_pairs']})",
        f"Quality evaluation ready: {summary['quality_ready']} (regression={summary['quality_regression']})", "",
        "## Conditions", "",
        "Wall, token, and cost medians below use successful runs only; pass, corrections, and timeouts use all usable cells.", "",
        "| condition | pass | successful median wall | successful median tokens | successful median cost | corrections | timeouts |",
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
        evidence = summary["fixture_evidence"][fixture]
        lines.append(
            f"- `{fixture}` ({FIXTURES[fixture].parallelism}): **{route}** "
            f"— latency pairs {evidence['latency_pairs']}/{evidence['pairs']}, "
            f"single-only {evidence['single_only_pairs']}, multi-only {evidence['multi_only_pairs']}, "
            f"censored {evidence['censored_pairs']}"
        )
    lines.extend(("", "Default multi adoption requires no pass-rate loss, median speedup ≥1.20x, and no blinded quality regression. Per-fixture routing requires ≥1.15x and the same quality gate.", ""))
    report = "\n".join(lines)
    (experiment / "report.md").write_text(report)
    (experiment / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    return report


def render_orchestration_report(
    experiment: Path, manifest: dict[str, Any], rows: list[dict[str, Any]], summary: dict[str, Any],
) -> str:
    def seconds(value: Optional[float]) -> str:
        return "-" if value is None else f"{value / 1000:.1f}s"

    lines = [
        "# Leader-worker orchestration study", "",
        f"- Experiment: `{manifest['run_id']}`",
        f"- Usable cells: {summary['usable_runs']} / {len(manifest['matrix'])}",
        f"- Protocol-degraded cells: {summary['protocol_degraded_runs']}", "",
        "## Conditions", "",
        "| condition | pass | median wall | median overlap | median pure wait |",
        "|---|---:|---:|---:|---:|",
    ]
    for condition in ORCHESTRATION_CONDITIONS:
        item = summary["conditions"][condition]
        lines.append(
            f"| {condition} | {item['passed']}/{item['runs']} | {seconds(item['median_wall_ms'])} | "
            f"{seconds(item['median_overlap_ms'])} | {seconds(item['median_pure_wait_ms'])} |"
        )
    lines.extend(("", "## Paired comparisons", ""))
    for name, comparison in summary["comparisons"].items():
        speed = comparison["median_speedup"]
        lines.append(
            f"- `{name}`: {comparison['latency_pairs']}/{comparison['pairs']} latency pairs, "
            f"median speedup {'-' if speed is None else f'{speed:.2f}x'}"
        )
    lines.extend((
        "",
        f"Latency gate ready: **{summary['latency_gate_ready']}**",
        f"Quality ready: **{summary['quality_ready']}** (regression={summary['quality_regression']})",
        f"Promotion ready: **{summary['promotion_ready']}**",
        "",
    ))
    report = "\n".join(lines)
    (experiment / "report.md").write_text(report)
    (experiment / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    return report


def render_partition_report(
    experiment: Path, manifest: dict[str, Any], rows: list[dict[str, Any]], summary: dict[str, Any],
) -> str:
    def seconds(value: Optional[float]) -> str:
        return "-" if value is None else f"{value / 1000:.1f}s"
    lines = [
        "# Worker task partition study", "",
        f"- Experiment: `{manifest['run_id']}`",
        f"- Usable cells: {summary['usable_runs']} / {len(manifest['matrix'])}",
        f"- Protocol-degraded cells: {summary['protocol_degraded_runs']}", "",
        "| condition | pass | median wall | median worker critical path |",
        "|---|---:|---:|---:|",
    ]
    for condition in PARTITION_CONDITIONS:
        item = summary["conditions"][condition]
        lines.append(
            f"| {condition} | {item['passed']}/{item['runs']} | {seconds(item['median_wall_ms'])} | "
            f"{seconds(item['median_worker_critical_ms'])} |"
        )
    speed = summary["median_speedup"]
    lines.extend((
        "",
        f"Paired broad/partitioned speedup: {'-' if speed is None else f'{speed:.2f}x'}",
        f"Latency pairs: {summary['latency_pairs']} / {manifest['trials']}", "",
    ))
    report = "\n".join(lines)
    (experiment / "report.md").write_text(report)
    (experiment / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    return report


def policy_pair_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    usable = latest_effectiveness_rows(rows)
    grouped: dict[tuple[str, int], dict[str, dict[str, Any]]] = {}
    for row in usable:
        if not row.get("infra_invalid"):
            grouped.setdefault((row["fixture"], int(row["trial"])), {})[row["condition"]] = row
    pairs = []
    for (fixture, trial), policies in sorted(grouped.items()):
        if set(policies) != set(POLICIES):
            continue
        legacy, adaptive = policies["legacy"], policies["adaptive"]
        both_passed = bool(legacy.get("acceptance_passed") and adaptive.get("acceptance_passed"))
        ratio = None
        if both_passed and legacy.get("total_wall_ms") and adaptive.get("total_wall_ms"):
            ratio = legacy["total_wall_ms"] / adaptive["total_wall_ms"]
        legacy_tokens = sum(int(legacy.get("tokens", {}).get(key, 0) or 0) for key in TOKEN_KEYS)
        adaptive_tokens = sum(int(adaptive.get("tokens", {}).get(key, 0) or 0) for key in TOKEN_KEYS)
        pairs.append({
            "fixture": fixture, "trial": trial,
            "legacy_passed": bool(legacy.get("acceptance_passed")),
            "adaptive_passed": bool(adaptive.get("acceptance_passed")),
            "outcome": (
                "both_success" if both_passed
                else "legacy_only" if legacy.get("acceptance_passed")
                else "adaptive_only" if adaptive.get("acceptance_passed")
                else "neither_success"
            ),
            "speedup": ratio,
            "token_ratio": (
                adaptive_tokens / legacy_tokens
                if both_passed and legacy_tokens else None
            ),
            "legacy_run_id": legacy["run_id"],
            "adaptive_run_id": adaptive["run_id"],
        })
    return pairs


def summarize_policy(rows: list[dict[str, Any]], *, seed: int) -> dict[str, Any]:
    usable = latest_effectiveness_rows(rows)
    conditions: dict[str, Any] = {}
    for policy in POLICIES:
        selected = [row for row in usable if row["condition"] == policy]
        passed = [row for row in selected if row.get("acceptance_passed")]
        latencies = [float(row["total_wall_ms"]) for row in passed if row.get("total_wall_ms") is not None]
        tokens = [sum(int(row.get("tokens", {}).get(key, 0) or 0) for key in TOKEN_KEYS) for row in passed]
        delegated = [row for row in selected if int(row.get("worker_tasks", 0) or 0) > 0]
        route_counts = {route: sum(row.get("routing_decision") == route for row in selected)
                        for route in ("direct", "probe", "parallel")}
        command_total = lambda key: sum(
            int(row.get("coordination_commands", {}).get(key, 0) or 0) for row in selected
        )
        conditions[policy] = {
            "runs": len(selected), "passed": len(passed),
            "pass_rate": len(passed) / len(selected) if selected else None,
            "median_wall_ms": statistics.median(latencies) if latencies else None,
            "median_tokens": statistics.median(tokens) if tokens else None,
            "delegated_runs": len(delegated),
            "delegation_rate": len(delegated) / len(selected) if selected else None,
            "route_counts": route_counts,
            "worker_tasks": sum(int(row.get("worker_tasks", 0) or 0) for row in selected),
            "wait_commands": command_total("wait"),
            "collect_commands": command_total("collect"),
            "read_commands": command_total("read"),
            "isolated_delegates": command_total("isolated_delegate"),
            "controller_dispatches": command_total("controller_dispatch"),
            "controller_collects": command_total("controller_collect"),
            "corrections": sum(int(row.get("correction_count", 0) or 0) for row in selected),
            "timeouts": sum(bool(row.get("timed_out")) for row in selected),
        }
    pairs = policy_pair_rows(usable)
    speedups = [float(pair["speedup"]) for pair in pairs if pair["speedup"] is not None]
    token_ratios = [float(pair["token_ratio"]) for pair in pairs if pair["token_ratio"] is not None]
    return {
        "conditions": conditions, "pairs": pairs,
        "paired_speedup_median": statistics.median(speedups) if speedups else None,
        "paired_speedup_bootstrap_95ci": bootstrap_ci(speedups, seed=seed),
        "token_ratio_median": statistics.median(token_ratios) if token_ratios else None,
        "latency_pairs": len(speedups),
        "censored_pairs": sum(pair["outcome"] == "neither_success" for pair in pairs),
        "attempt_runs": len(rows), "usable_runs": len(usable),
        "infra_invalid_runs": sum(
            bool(row.get("infra_invalid")) or row.get("total_wall_ms") is None for row in rows
        ),
    }


def render_policy_report(
    experiment: Path, manifest: dict[str, Any], rows: list[dict[str, Any]], summary: dict[str, Any],
) -> str:
    def ratio(value: Optional[float]) -> str:
        return "-" if value is None else f"{value:.2f}x"
    lines = [
        "# Project leader policy A/B", "",
        f"- Experiment: `{manifest['run_id']}`",
        f"- Model/effort: `{manifest['model']}` / `{manifest['effort']}`",
        f"- Usable cells: {summary['usable_runs']} / {len(manifest['matrix'])}", "",
        "## Result", "",
        f"Paired median speedup (legacy/adaptive): {ratio(summary['paired_speedup_median'])}",
        f"Bootstrap 95% CI: {summary['paired_speedup_bootstrap_95ci']}",
        f"Median token ratio (adaptive/legacy): {ratio(summary['token_ratio_median'])}",
        f"Latency-comparable pairs: {summary['latency_pairs']} / {len(summary['pairs'])} "
        f"(both-failed/censored {summary['censored_pairs']})", "",
        "## Conditions", "",
        "| policy | pass | median wall | median tokens | routes d/p/p | delegated runs | worker tasks | controller dispatch/collect | corrections | timeouts |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for policy in POLICIES:
        item = summary["conditions"][policy]
        wall = "-" if item["median_wall_ms"] is None else f"{item['median_wall_ms'] / 1000:.1f}s"
        lines.append(
            f"| {policy} | {item['passed']}/{item['runs']} | {wall} | {item['median_tokens'] or '-'} | "
            f"{item['route_counts']['direct']}/{item['route_counts']['probe']}/{item['route_counts']['parallel']} | "
            f"{item['delegated_runs']}/{item['runs']} | {item['worker_tasks']} | "
            f"{item['controller_dispatches']}/{item['controller_collects']} | "
            f"{item['corrections']} | {item['timeouts']} |"
        )
    lines.extend((
        "",
        "Timeout은 완료시간으로 대입하지 않으며 successful pair만 latency/token ratio에 포함한다. "
        "Team 생성 시간은 양쪽 모두 end-to-end wall time에 포함된다.", "",
    ))
    report = "\n".join(lines)
    (experiment / "report.md").write_text(report)
    (experiment / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    return report


def regenerate_experiment_report(
    experiment: Path, manifest: dict[str, Any], rows: list[dict[str, Any]],
    quality: Optional[dict[str, Any]] = None,
) -> str:
    """Render the schema selected by the immutable experiment manifest."""
    if manifest.get("experiment_type") == "project-leader-policy-ab":
        return render_policy_report(
            experiment, manifest, rows,
            summarize_policy(rows, seed=int(manifest["seed"])),
        )
    if manifest.get("experiment_type") == "leader-worker-orchestration":
        return render_orchestration_report(
            experiment, manifest, rows,
            summarize_orchestration(rows, seed=int(manifest["seed"]), quality=quality),
        )
    if manifest.get("experiment_type") == "worker-task-partition":
        return render_partition_report(
            experiment, manifest, rows, summarize_partition(rows, seed=int(manifest["seed"])),
        )
    return render_report(
        experiment, manifest, rows,
        summarize(rows, seed=int(manifest["seed"]), quality=quality),
    )


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
    preserve_scratch = False
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


def run_orchestration_experiment(args: argparse.Namespace) -> int:
    fixtures = tuple(item for item in args.fixtures.split(",") if item)
    conditions = tuple(item for item in args.conditions.split(",") if item)
    unknown = set(fixtures) - set(FIXTURES)
    unknown_conditions = set(conditions) - set(ORCHESTRATION_CONDITIONS)
    if unknown or unknown_conditions or not conditions or args.trials < 1 or args.timeout < 1:
        raise ValueError(
            f"invalid fixtures={sorted(unknown)} conditions={sorted(unknown_conditions)} "
            f"trials={args.trials} timeout={args.timeout}"
        )
    specs = build_orchestration_matrix(fixtures, args.trials, args.seed, conditions)
    print(f"orchestration matrix: {len(specs)} runs")
    for index, spec in enumerate(specs, 1):
        print(f"  {index:02d}. {spec.fixture:<22} trial={spec.trial} order={spec.order} {spec.condition}")
    if args.dry_run:
        return 0
    if not shutil.which("claude") or not shutil.which("tm-agent"):
        raise RuntimeError("claude and tm-agent CLIs are required")
    run_id = args.run_id or datetime.now().strftime("%Y%m%dT%H%M%S") + "-orchestration-" + uuid.uuid4().hex[:6]
    experiment = args.results_dir / run_id
    experiment.mkdir(parents=True, exist_ok=False)
    (experiment / "runs").mkdir()
    manifest = {
        "schema": 1, "experiment_type": "leader-worker-orchestration",
        "orchestration_schema": 1, "run_id": run_id, "created_at": utc_now(),
        "root_head": git("rev-parse", "HEAD"), "model": args.model, "effort": args.effort,
        "workers": 3, "trials": args.trials, "seed": args.seed,
        "timeout_seconds": args.timeout, "xcode_host": args.xcode_host,
        "fixtures": [row for row in validate_fixture_metadata() if row["fixture"] in fixtures],
        "matrix": [asdict(spec) for spec in specs],
    }
    manifest_path = experiment / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    manifest_path.chmod(0o444)
    scratch = Path(tempfile.mkdtemp(prefix="term-mesh-orchestration-"))
    rows = []
    try:
        for index, spec in enumerate(specs, 1):
            print(f"[{index}/{len(specs)}] {spec.fixture} {spec.condition} trial {spec.trial}", flush=True)
            result = run_orchestration_one(
                spec, experiment=experiment, scratch=scratch, model=args.model, effort=args.effort,
                timeout=args.timeout, xcode_host=args.xcode_host, keep_checkouts=args.keep_checkouts,
            )
            rows.append(asdict(result))
            render_orchestration_report(
                experiment, manifest, rows, summarize_orchestration(rows, seed=args.seed),
            )
            print(f"  {result.status.upper()} {(result.total_wall_ms or 0) / 1000:.1f}s {result.failure_reason or ''}")
    finally:
        if not args.keep_checkouts:
            shutil.rmtree(scratch, ignore_errors=True)
    print(f"Saved: {experiment}")
    effective_rows = latest_effectiveness_rows(rows)
    return 0 if len(effective_rows) == len(specs) and all(row["acceptance_passed"] for row in effective_rows) else 1


def run_partition_experiment(args: argparse.Namespace) -> int:
    fixtures = tuple(item for item in args.fixtures.split(",") if item)
    conditions = tuple(item for item in args.conditions.split(",") if item)
    unknown = set(fixtures) - set(PARTITION_FIXTURES)
    unknown_conditions = set(conditions) - set(PARTITION_CONDITIONS)
    if unknown or unknown_conditions or not conditions or args.trials < 1 or args.timeout < 1:
        raise ValueError(
            f"invalid fixtures={sorted(unknown)} conditions={sorted(unknown_conditions)} "
            f"trials={args.trials} timeout={args.timeout}"
        )
    specs = build_partition_matrix(fixtures, args.trials, conditions)
    print(f"partition matrix: {len(specs)} runs")
    for index, spec in enumerate(specs, 1):
        print(f"  {index:02d}. {spec.fixture:<22} trial={spec.trial} order={spec.order} {spec.condition}")
    if args.dry_run:
        return 0
    if not shutil.which("claude") or not shutil.which("tm-agent"):
        raise RuntimeError("claude and tm-agent CLIs are required")
    run_id = args.run_id or datetime.now().strftime("%Y%m%dT%H%M%S") + "-partition-" + uuid.uuid4().hex[:6]
    experiment = args.results_dir / run_id
    experiment.mkdir(parents=True, exist_ok=False)
    (experiment / "runs").mkdir()
    manifest = {
        "schema": 1, "experiment_type": "worker-task-partition",
        "run_id": run_id, "created_at": utc_now(), "root_head": git("rev-parse", "HEAD"),
        "model": args.model, "effort": args.effort, "workers": 3, "trials": args.trials,
        "seed": args.seed, "timeout_seconds": args.timeout, "xcode_host": args.xcode_host,
        "fixtures": [row for row in validate_fixture_metadata() if row["fixture"] in fixtures],
        "matrix": [asdict(spec) for spec in specs],
    }
    manifest_path = experiment / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    manifest_path.chmod(0o444)
    scratch = Path(tempfile.mkdtemp(prefix="term-mesh-partition-"))
    rows = []
    try:
        for index, spec in enumerate(specs, 1):
            print(f"[{index}/{len(specs)}] {spec.fixture} {spec.condition} trial {spec.trial}", flush=True)
            fixture = FIXTURES[spec.fixture]
            tasks = default_worker_tasks() if spec.condition == "broad" else partitioned_worker_tasks(fixture)
            runtime_spec = RunSpec(spec.fixture, spec.trial, "blocking", spec.order)
            result = run_orchestration_one(
                runtime_spec, experiment=experiment, scratch=scratch, model=args.model, effort=args.effort,
                timeout=args.timeout, xcode_host=args.xcode_host, keep_checkouts=args.keep_checkouts,
                worker_tasks=tasks,
            )
            result.condition = spec.condition
            (experiment / result.paths["result"]).write_text(
                json.dumps(asdict(result), indent=2, ensure_ascii=False) + "\n"
            )
            rows.append(asdict(result))
            render_partition_report(
                experiment, manifest, rows, summarize_partition(rows, seed=args.seed),
            )
            print(f"  {result.status.upper()} {(result.total_wall_ms or 0) / 1000:.1f}s {result.failure_reason or ''}")
    finally:
        if not args.keep_checkouts:
            shutil.rmtree(scratch, ignore_errors=True)
    print(f"Saved: {experiment}")
    effective_rows = latest_effectiveness_rows(rows)
    return 0 if len(effective_rows) == len(specs) and all(row["acceptance_passed"] for row in effective_rows) else 1


def run_isolated_topology_experiment(args: argparse.Namespace) -> int:
    fixtures = tuple(item for item in args.fixtures.split(",") if item)
    conditions = tuple(item for item in args.conditions.split(",") if item)
    unknown = set(fixtures) - set(PARTITION_FIXTURES)
    unknown_conditions = set(conditions) - set(ISOLATED_TOPOLOGY_CONDITIONS)
    if unknown or unknown_conditions or not conditions or args.trials < 1 or args.timeout < 1:
        raise ValueError(f"invalid fixtures={sorted(unknown)} conditions={sorted(unknown_conditions)} trials={args.trials}")
    specs = build_isolated_topology_matrix(fixtures, args.trials, conditions)
    print(f"isolated topology matrix: {len(specs)} runs")
    for index, spec in enumerate(specs, 1):
        print(f"  {index:02d}. {spec.fixture:<22} trial={spec.trial} order={spec.order} {spec.condition}")
    if args.dry_run: return 0
    run_id = args.run_id or datetime.now().strftime("%Y%m%dT%H%M%S") + "-isolated-" + uuid.uuid4().hex[:6]
    experiment = args.results_dir / run_id; experiment.mkdir(parents=True, exist_ok=False); (experiment / "runs").mkdir()
    manifest = {
        "schema": 1, "experiment_type": "isolated-leader-worker-topology", "run_id": run_id,
        "created_at": utc_now(), "root_head": git("rev-parse", "HEAD"), "model": args.model,
        "effort": args.effort, "workers": 3, "trials": args.trials, "seed": args.seed,
        "timeout_seconds": args.timeout, "xcode_host": args.xcode_host,
        "fixtures": [row for row in validate_fixture_metadata() if row["fixture"] in fixtures],
        "matrix": [asdict(spec) for spec in specs],
    }
    (experiment / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    preserve_scratch = False
    scratch = Path(tempfile.mkdtemp(prefix="term-mesh-isolated-topology-")); rows = []
    try:
        for index, spec in enumerate(specs, 1):
            print(f"[{index}/{len(specs)}] {spec.fixture} {spec.condition} trial {spec.trial}", flush=True)
            result = run_isolated_topology_one(
                spec, experiment=experiment, scratch=scratch, model=args.model, effort=args.effort,
                timeout=args.timeout, xcode_host=args.xcode_host, keep_checkouts=args.keep_checkouts,
            )
            rows.append(asdict(result)); print(f"  {result.status.upper()} {(result.total_wall_ms or 0)/1000:.1f}s {result.failure_reason or ''}")
            if not result.cleanup_safe:
                preserve_scratch = True
                print(f"  STOPPED: unsafe cleanup; preserved scratch at {scratch}")
                break
    finally:
        if not args.keep_checkouts and not preserve_scratch: shutil.rmtree(scratch, ignore_errors=True)
    print(f"Saved: {experiment}")
    effective = latest_effectiveness_rows(rows)
    return 0 if len(effective) == len(specs) and all(row["acceptance_passed"] for row in effective) else 1


def run_policy_experiment(args: argparse.Namespace) -> int:
    fixtures = tuple(item for item in args.fixtures.split(",") if item)
    policies = tuple(item for item in args.policies.split(",") if item)
    unknown = set(fixtures) - set(FIXTURES)
    unknown_policies = set(policies) - set(POLICIES)
    if unknown or unknown_policies or not policies or args.trials < 1 or args.timeout < 1:
        raise ValueError(
            f"invalid fixtures={sorted(unknown)} policies={sorted(unknown_policies)} "
            f"trials={args.trials} timeout={args.timeout}"
        )
    specs = build_policy_matrix(fixtures, args.trials, args.seed, policies)
    print(f"policy A/B matrix: {len(specs)} runs")
    for index, spec in enumerate(specs, 1):
        print(f"  {index:02d}. {spec.fixture:<22} pair={spec.trial} order={spec.order} {spec.condition}")
    if args.dry_run:
        return 0
    if not shutil.which("claude") or not shutil.which("tm-agent"):
        raise RuntimeError("claude and tm-agent CLIs are required")
    run_id = args.run_id or datetime.now().strftime("%Y%m%dT%H%M%S") + "-policy-" + uuid.uuid4().hex[:6]
    experiment = args.results_dir / run_id
    experiment.mkdir(parents=True, exist_ok=False)
    (experiment / "runs").mkdir()
    manifest = {
        "schema": 1, "experiment_type": "project-leader-policy-ab",
        "run_id": run_id, "created_at": utc_now(), "root_head": git("rev-parse", "HEAD"),
        "model": args.model, "effort": args.effort, "workers": 3,
        "trials": args.trials, "seed": args.seed, "timeout_seconds": args.timeout,
        "xcode_host": args.xcode_host, "host": os.uname().nodename,
        "architecture": os.uname().machine, "policies": list(policies),
        "policy_prompts": {"legacy": LEGACY_POLICY, "adaptive": ADAPTIVE_POLICY},
        "fixtures": [row for row in validate_fixture_metadata() if row["fixture"] in fixtures],
        "matrix": [asdict(spec) for spec in specs],
    }
    manifest_path = experiment / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    manifest_path.chmod(0o444)
    rows: list[dict[str, Any]] = []
    scratch = Path(tempfile.mkdtemp(prefix="term-mesh-policy-ab-"))
    try:
        for index, spec in enumerate(specs, 1):
            print(f"[{index}/{len(specs)}] {spec.fixture} {spec.condition} pair {spec.trial}", flush=True)
            result = run_policy_one(
                spec, experiment=experiment, scratch=scratch, model=args.model, effort=args.effort,
                timeout=args.timeout, xcode_host=args.xcode_host, keep_checkouts=args.keep_checkouts,
            )
            rows.append(asdict(result))
            print(f"  {result.status.upper()} {(result.total_wall_ms or 0) / 1000:.1f}s {result.failure_reason or ''}")
            render_policy_report(experiment, manifest, rows, summarize_policy(rows, seed=args.seed))
    finally:
        if not args.keep_checkouts:
            shutil.rmtree(scratch, ignore_errors=True)
    print(f"Saved: {experiment}")
    return 0 if all(row["acceptance_passed"] for row in latest_effectiveness_rows(rows)) else 1


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
    orchestration = sub.add_parser(
        "orchestration-study", help="compare single, blocking, and overlapping leader-worker execution",
    )
    orchestration.add_argument("--fixtures", default=",".join(FIXTURES))
    orchestration.add_argument("--conditions", default=",".join(ORCHESTRATION_CONDITIONS))
    orchestration.add_argument("--trials", type=int, default=3)
    orchestration.add_argument("--seed", type=int, default=DEFAULT_SEED)
    orchestration.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    orchestration.add_argument("--model", default="sonnet")
    orchestration.add_argument("--effort", default="medium", choices=("low", "medium", "high", "xhigh", "max"))
    orchestration.add_argument("--xcode-host", default="mac-sub")
    orchestration.add_argument("--results-dir", type=Path, default=DEFAULT_RESULTS / "orchestration-study")
    orchestration.add_argument("--run-id")
    orchestration.add_argument("--dry-run", action="store_true")
    orchestration.add_argument("--keep-checkouts", action="store_true")
    partition = sub.add_parser(
        "partition-study", help="compare broad and exact-path worker task capsules",
    )
    partition.add_argument("--fixtures", default=",".join(PARTITION_FIXTURES))
    partition.add_argument("--conditions", default=",".join(PARTITION_CONDITIONS))
    partition.add_argument("--trials", type=int, default=3)
    partition.add_argument("--seed", type=int, default=DEFAULT_SEED)
    partition.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    partition.add_argument("--model", default="sonnet")
    partition.add_argument("--effort", default="medium", choices=("low", "medium", "high", "xhigh", "max"))
    partition.add_argument("--xcode-host", default="mac-sub")
    partition.add_argument("--results-dir", type=Path, default=DEFAULT_RESULTS / "partition-study")
    partition.add_argument("--run-id")
    partition.add_argument("--dry-run", action="store_true")
    partition.add_argument("--keep-checkouts", action="store_true")
    isolated = sub.add_parser("isolated-topology-study", help="compare leader blocking and overlap with isolated worker checkouts")
    isolated.add_argument("--fixtures", default=",".join(PARTITION_FIXTURES))
    isolated.add_argument("--conditions", default=",".join(ISOLATED_TOPOLOGY_CONDITIONS))
    isolated.add_argument("--trials", type=int, default=3); isolated.add_argument("--seed", type=int, default=DEFAULT_SEED)
    isolated.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT); isolated.add_argument("--model", default="sonnet")
    isolated.add_argument("--effort", default="medium", choices=("low","medium","high","xhigh","max"))
    isolated.add_argument("--xcode-host", default="mac-sub")
    isolated.add_argument("--results-dir", type=Path, default=DEFAULT_RESULTS / "isolated-topology-study")
    isolated.add_argument("--run-id"); isolated.add_argument("--dry-run", action="store_true"); isolated.add_argument("--keep-checkouts", action="store_true")
    policy = sub.add_parser("policy-ab", help="compare legacy delegate-first and adaptive Project leaders")
    policy.add_argument("--fixtures", default=",".join(FIXTURES))
    policy.add_argument("--policies", default=",".join(POLICIES))
    policy.add_argument("--trials", type=int, default=3)
    policy.add_argument("--seed", type=int, default=DEFAULT_SEED)
    policy.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    policy.add_argument("--model", default="sonnet")
    policy.add_argument("--effort", default="medium", choices=("low", "medium", "high", "xhigh", "max"))
    policy.add_argument("--xcode-host", default="mac-sub")
    policy.add_argument("--results-dir", type=Path, default=DEFAULT_RESULTS / "policy-ab")
    policy.add_argument("--run-id")
    policy.add_argument("--dry-run", action="store_true")
    policy.add_argument("--keep-checkouts", action="store_true")
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
    if args.command == "orchestration-study":
        if args.dry_run:
            return run_orchestration_experiment(args)
        with benchmark_signal_cleanup(), benchmark_run_lock(args.results_dir):
            return run_orchestration_experiment(args)
    if args.command == "partition-study":
        if args.dry_run:
            return run_partition_experiment(args)
        with benchmark_signal_cleanup(), benchmark_run_lock(args.results_dir):
            return run_partition_experiment(args)
    if args.command == "isolated-topology-study":
        if args.dry_run: return run_isolated_topology_experiment(args)
        with benchmark_signal_cleanup(), benchmark_run_lock(args.results_dir):
            return run_isolated_topology_experiment(args)
    if args.command == "policy-ab":
        with benchmark_signal_cleanup(), benchmark_run_lock(args.results_dir):
            return run_policy_experiment(args)
    experiment = args.experiment if args.experiment.is_dir() else args.experiment.parent
    manifest, rows = load_experiment(experiment)
    quality = (
        evaluate_orchestration_quality(experiment, rows, int(manifest["seed"]))
        if args.evaluate and manifest.get("experiment_type") == "leader-worker-orchestration" else
        evaluate_quality(experiment, rows, int(manifest["seed"])) if args.evaluate else None
    )
    if quality is None and (experiment / "quality-eval.json").exists():
        quality = json.loads((experiment / "quality-eval.json").read_text())
    print(regenerate_experiment_report(experiment, manifest, rows, quality))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
