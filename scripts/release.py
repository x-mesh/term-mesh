#!/usr/bin/env python3
"""Resumable term-mesh release state machine.

The conversational /release wrappers write release notes and ask for approval.
This script owns ordering, durable receipts, exact-SHA checks, and resume.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from contextlib import contextmanager
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
REPO = "x-mesh/term-mesh"
RELEASE_WORKTREES = Path.home() / ".cache/term-mesh/release-worktrees"
RELEASE_WORKTREE_NAME = re.compile(r"^v(\d+\.\d+\.\d+)-(?:source|artifact-[0-9a-f]+)$")
STEP_ORDER = [
    "develop_to_main",
    "release_metadata",
    "release_pr",
    "release_merge",
    "tag",
    "release_build",
    "dsym",
    "dmg",
    "github_release",
    "homebrew",
    "develop_resync",
    "verify",
    "cleanup",
]
RELAY_E2E_PATH_PREFIXES = (
    "Sources/Peer",
    "Sources/RemoteHostStore.swift",
    "Sources/SessionHostPanes.swift",
    "Sources/TeamOrchestrator",
    "Sources/Workspace.swift",
    "Sources/TabManager.swift",
    "proto/peer/",
    "daemon/peer-proto/",
    "daemon/term-meshd/src/peer/",
    "swift/PeerProto/",
    "tests_v2/test_remote_project",
    "scripts/run-tests-v2.sh",
)


class ReleaseError(RuntimeError):
    pass


def run(
    *args: str,
    cwd: Path = ROOT,
    input_text: str | None = None,
    check: bool = True,
) -> str:
    if args and args[0] not in {"git", "grep", "shasum"}:
        print(f"[release] run: {' '.join(args)}", file=sys.stderr, flush=True)
    proc = subprocess.run(
        args, cwd=cwd, input=input_text, text=True, capture_output=True, check=False
    )
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        if len(detail) > 12000:
            detail = "… output truncated …\n" + detail[-12000:]
        raise ReleaseError(f"{' '.join(args)} failed ({proc.returncode}): {detail}")
    return proc.stdout.strip()


def git(*args: str, cwd: Path = ROOT) -> str:
    return run("git", *args, cwd=cwd)


def gk(*args: str, cwd: Path = ROOT, input_text: str | None = None) -> dict[str, Any]:
    env = os.environ.copy()
    env["GK_AGENT"] = "1"
    proc = subprocess.run(
        ("git-kit", *args), cwd=cwd, input=input_text, text=True,
        capture_output=True, check=False, env=env,
    )
    raw = proc.stdout.strip()
    diagnostic = proc.stderr.strip()
    try:
        envelope = json.loads(raw or diagnostic)
    except json.JSONDecodeError as exc:
        detail = raw or diagnostic
        if proc.returncode == 0:
            return {
                "schema": 1,
                "state": "ok",
                "ok": True,
                "result": {"output": detail},
            }
        raise ReleaseError(f"git-kit returned non-JSON output: {detail[-1000:]}") from exc
    if proc.returncode != 0 or envelope.get("state") != "ok":
        raise ReleaseError(f"git-kit {args[0]} failed: {json.dumps(envelope, ensure_ascii=False)}")
    return envelope


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def normalize_version(value: str) -> str:
    value = value.removeprefix("v")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        raise ReleaseError(f"invalid SemVer: {value}")
    return value


def current_version(ref: str = "origin/develop") -> str:
    body = git("show", f"{ref}:GhosttyTabs.xcodeproj/project.pbxproj")
    match = re.search(r"MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+);", body)
    if not match:
        raise ReleaseError(f"MARKETING_VERSION not found at {ref}")
    return match.group(1)


def next_minor(value: str) -> str:
    major, minor, _ = map(int, normalize_version(value).split("."))
    return f"{major}.{minor + 1}.0"


def state_dir() -> Path:
    override = os.environ.get("TERMMESH_RELEASE_STATE_DIR")
    if override:
        path = Path(override).expanduser().resolve()
        path.mkdir(parents=True, exist_ok=True)
        return path
    common = Path(git("rev-parse", "--git-common-dir"))
    if not common.is_absolute():
        common = (ROOT / common).resolve()
    path = common / "term-mesh-releases"
    path.mkdir(parents=True, exist_ok=True)
    return path


def state_path(version: str) -> Path:
    return state_dir() / f"v{normalize_version(version)}.json"


def load_state(version: str) -> dict[str, Any]:
    path = state_path(version)
    if not path.exists():
        raise ReleaseError(f"no release state for v{version}; run plan first")
    state = json.loads(path.read_text())
    for name in STEP_ORDER:
        state["steps"].setdefault(name, {"status": "pending"})
    return state


def save_state(state: dict[str, Any]) -> None:
    state["updated_at"] = utc_now()
    path = state_path(state["version"])
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


@contextmanager
def release_lock(version: str):
    lock_name = "plan" if version == "auto" else f"v{normalize_version(version)}"
    path = state_dir() / f"{lock_name}.lock"
    with path.open("w") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ReleaseError(f"release v{version} is already running") from exc
        handle.write(f"pid={os.getpid()}\n")
        handle.flush()
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def completed(state: dict[str, Any], step: str) -> bool:
    return state["steps"][step]["status"] == "completed"


def begin(state: dict[str, Any], step: str) -> None:
    state["steps"][step] = {"status": "running", "started_at": utc_now()}
    save_state(state)


def mark(state: dict[str, Any], step: str, **receipt: Any) -> None:
    state["steps"][step] = {
        "status": "completed",
        "completed_at": utc_now(),
        **receipt,
    }
    save_state(state)


def record_failure(version: str, error: str) -> None:
    try:
        state = load_state(version)
    except (ReleaseError, OSError, json.JSONDecodeError):
        return
    for step in STEP_ORDER:
        if state["steps"][step]["status"] == "running":
            state["steps"][step] = {
                **state["steps"][step],
                "status": "failed",
                "failed_at": utc_now(),
                "error": error,
            }
            save_state(state)
            return


def emit(state: dict[str, Any], *, command: str) -> None:
    pending = [name for name in STEP_ORDER if not completed(state, name)]
    print(json.dumps({
        "schema": 1,
        "state": "complete" if not pending else "ready",
        "command": command,
        "version": state["version"],
        "candidate_develop_sha": state["candidate_develop_sha"],
        "candidate_main_sha": state["candidate_main_sha"],
        "latest_tag": state["latest_tag"],
        "completed": [name for name in STEP_ORDER if completed(state, name)],
        "pending": pending,
        "next_action": pending[0] if pending else None,
        "resume_command": None if not pending else f"python3 scripts/release.py resume {state['version']} --yes --json",
        "receipts": state["steps"],
    }, indent=2, ensure_ascii=False))


def remote_sha(branch: str) -> str:
    return git("rev-parse", f"origin/{branch}")


def valid_release_product(product: Path, dsym: Path, version: str, commit: str) -> bool:
    if not product.is_dir() or not dsym.is_dir():
        return False
    plist = product / "Contents/Info.plist"
    binary = product / "Contents/MacOS/term-mesh"
    if not plist.is_file() or not binary.is_file():
        return False
    embedded = run("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString",
                   str(plist), check=False)
    embedded_commit = run("/usr/libexec/PlistBuddy", "-c", "Print :TermMeshCommit",
                          str(plist), check=False)
    app_uuid = run("dwarfdump", "--uuid", str(binary), check=False).split()
    dsym_uuid = run("dwarfdump", "--uuid", str(dsym), check=False).split()
    return (
        embedded == version
        and embedded_commit == commit[:9]
        and len(app_uuid) >= 2
        and len(dsym_uuid) >= 2
        and app_uuid[1] == dsym_uuid[1]
    )


def homebrew_cask() -> tuple[str, str] | None:
    raw = run("gh", "api", "repos/x-mesh/homebrew-tap/contents/Casks/term-mesh.rb?ref=main",
              "--jq", ".content", check=False)
    if not raw:
        return None
    try:
        body = base64.b64decode(raw).decode()
    except (ValueError, UnicodeDecodeError):
        return None
    version = re.search(r'^  version "([^"]+)"$', body, re.M)
    sha = re.search(r'^  sha256 "([0-9a-f]{64})"$', body, re.M)
    return (version.group(1), sha.group(1)) if version and sha else None


def fetch() -> None:
    run("git", "fetch", "origin", "main", "develop", "--tags")


def ensure_approved(args: argparse.Namespace) -> None:
    if not args.yes:
        raise ReleaseError("remote release mutations require --yes after user approval")


def validate_relay_e2e_receipt(receipt: dict[str, Any], candidate_sha: str) -> None:
    """Reject release evidence that does not prove the production failure boundary."""
    required_phases = {"create", "adopt", "reconnect", "cleanup"}
    phases = receipt.get("phases")
    if receipt.get("schema") != 1:
        raise ReleaseError("relay E2E receipt has an unsupported schema")
    if receipt.get("candidate_sha") != candidate_sha:
        raise ReleaseError("relay E2E receipt does not match the planned develop SHA")
    if receipt.get("remote_fixture_candidate_sha") != candidate_sha:
        raise ReleaseError(
            "relay E2E remote daemon was not built from the planned develop SHA"
        )
    if not receipt.get("remote_fixture_version"):
        raise ReleaseError("relay E2E receipt is missing the remote daemon version")
    if receipt.get("result") != "pass" or receipt.get("skipped") is not False:
        raise ReleaseError("relay E2E receipt is not an unskipped pass")
    if receipt.get("required_topology") is not True:
        raise ReleaseError("relay E2E receipt did not use the required topology")
    if not isinstance(phases, dict) or any(phases.get(name) != "pass" for name in required_phases):
        raise ReleaseError("relay E2E receipt did not pass create/adopt/reconnect/cleanup")
    if receipt.get("exact_surface_preserved") is not True:
        raise ReleaseError("relay E2E receipt did not preserve the exact leader surface")
    if float(receipt.get("leader_relay_stability_seconds") or 0) < 15:
        raise ReleaseError("relay E2E receipt did not hold attachment for 15 seconds")
    if float(receipt.get("background_restore_hold_seconds") or 0) < 12:
        raise ReleaseError("relay E2E receipt did not hold the restored Project in background past timeout")
    if receipt.get("saw_first_byte") is not True:
        raise ReleaseError("relay E2E receipt saw no leader relay bytes")
    if int(receipt.get("bytes_received") or 0) <= 0:
        raise ReleaseError("relay E2E receipt has zero leader relay bytes")
    if not receipt.get("leader_surface_id"):
        raise ReleaseError("relay E2E receipt is missing leader surface identity")
    if receipt.get("leader_process_active_known") is not True:
        raise ReleaseError("relay E2E receipt lacks authoritative leader process liveness")
    if receipt.get("leader_process_active") is not True:
        raise ReleaseError("relay E2E receipt points at an inactive leader process")
    tested_at = int(receipt.get("tested_at_unix") or 0)
    if tested_at <= 0 or abs(time.time() - tested_at) > 6 * 60 * 60:
        raise ReleaseError("relay E2E receipt is missing or older than six hours")


def require_relay_e2e_receipt(
    state: dict[str, Any], receipt_path: str | None
) -> dict[str, Any]:
    receipt = state.get("relay_e2e_receipt")
    if receipt_path:
        try:
            receipt = json.loads(Path(receipt_path).read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise ReleaseError(f"could not read relay E2E receipt: {exc}") from exc
    if not isinstance(receipt, dict):
        raise ReleaseError(
            "prepare requires --relay-e2e-receipt from the required mac-sub relay E2E"
        )
    validate_relay_e2e_receipt(receipt, state["candidate_develop_sha"])
    state["relay_e2e_receipt"] = receipt
    save_state(state)
    return receipt


def relay_e2e_required_for_paths(paths: list[str]) -> bool:
    return any(path.startswith(RELAY_E2E_PATH_PREFIXES) for path in paths)


def candidate_changed_paths(state: dict[str, Any]) -> list[str]:
    base = state.get("latest_tag") or state["candidate_main_sha"]
    output = git(
        "diff", "--name-only", f"{base}..{state['candidate_develop_sha']}", "--"
    )
    return [line for line in output.splitlines() if line]


def plan(args: argparse.Namespace) -> dict[str, Any]:
    fetch()
    rate = gh_json("api", "rate_limit")
    graphql = rate["resources"]["graphql"]
    if graphql["remaining"] < 500:
        raise ReleaseError(f"GitHub GraphQL budget too low: {graphql['remaining']}/5000, reset={graphql['reset']}")
    version = normalize_version(args.version or next_minor(current_version()))
    path = state_path(version)
    if path.exists():
        existing = load_state(version)
        if not args.reset:
            return existing
        if any(existing["steps"][name]["status"] != "pending" for name in STEP_ORDER):
            raise ReleaseError("cannot reset a release after execution has started")
    latest_tag = git("describe", "--tags", "--abbrev=0", "origin/main")
    if git("tag", "-l", f"v{version}"):
        raise ReleaseError(f"tag v{version} already exists")
    wip = git("log", "--format=%s", "origin/main..origin/develop", "--no-merges")
    wip = [line for line in wip.splitlines() if re.search(r"(^|[ (:])WIP([ (:]|$)", line, re.I)]
    if wip:
        raise ReleaseError(f"WIP commits would ship: {wip}")
    develop_sha = remote_sha("develop")
    main_sha = remote_sha("main")
    unreleased = git("log", "--format=%H", f"{latest_tag}..{develop_sha}").splitlines()
    if not unreleased:
        raise ReleaseError(f"no commits to release after {latest_tag}")
    if subprocess.run(("git", "merge-base", "--is-ancestor", main_sha, develop_sha),
                      cwd=ROOT, check=False).returncode != 0:
        raise ReleaseError("origin/develop does not contain origin/main; sync integration history first")
    run("git", "merge-tree", "--write-tree", main_sha, develop_sha)
    state = {
        "schema": 1,
        "version": version,
        "created_at": utc_now(),
        "candidate_develop_sha": develop_sha,
        "candidate_main_sha": main_sha,
        "latest_tag": latest_tag,
        "unreleased_commit_count": len(unreleased),
        "release_branch": f"chore/release-v{version}",
        "notes": None,
        "steps": {name: {"status": "pending"} for name in STEP_ORDER},
    }
    save_state(state)
    return state


def gh_json(*args: str) -> Any:
    raw = run("gh", *args)
    return json.loads(raw) if raw else None


def find_pr(head: str, base: str) -> int | None:
    rows = gh_json("pr", "list", "--repo", REPO, "--head", head, "--base", base,
                   "--state", "open", "--json", "number")
    return rows[0]["number"] if rows else None


def merge_develop_to_main(state: dict[str, Any]) -> None:
    if completed(state, "develop_to_main"):
        return
    begin(state, "develop_to_main")
    fetch()
    if remote_sha("develop") != state["candidate_develop_sha"]:
        raise ReleaseError("origin/develop changed after plan; rerun plan --reset")
    ancestor = subprocess.run(
        ("git", "merge-base", "--is-ancestor", state["candidate_develop_sha"], "origin/main"),
        cwd=ROOT, check=False,
    ).returncode == 0
    pr = None
    if not ancestor:
        pr = find_pr("develop", "main")
        if pr is None:
            url = run("gh", "pr", "create", "--repo", REPO, "--base", "main",
                      "--head", "develop", "--title", f"Merge develop into main for v{state['version']}",
                      "--body", "Preserve develop history before preparing the release. Merge commit required.")
            pr = int(url.rsplit("/", 1)[-1])
        run("gh", "pr", "merge", str(pr), "--repo", REPO, "--merge")
        fetch()
    main_sha = remote_sha("main")
    if subprocess.run(("git", "merge-base", "--is-ancestor", state["candidate_develop_sha"], main_sha),
                      cwd=ROOT, check=False).returncode != 0:
        raise ReleaseError("merged main does not contain the planned develop SHA")
    mark(state, "develop_to_main", pr=pr, main_sha=main_sha)


def release_worktree(state: dict[str, Any], ref: str, *, artifact: bool = False) -> Path:
    suffix = f"artifact-{ref[:12]}" if artifact else "source"
    path = RELEASE_WORKTREES / f"v{state['version']}-{suffix}"
    if path.exists():
        actual = git("-C", str(path), "rev-parse", "HEAD")
        if artifact:
            if actual != ref or git("-C", str(path), "status", "--porcelain"):
                raise ReleaseError(f"artifact worktree mismatch or dirty: {path} ({actual} != {ref})")
        else:
            branch = git("-C", str(path), "branch", "--show-current")
            if branch != state["release_branch"]:
                raise ReleaseError(f"release worktree has the wrong branch: {branch}")
            if actual != ref:
                parent = git("-C", str(path), "rev-parse", "HEAD^")
                subject = git("-C", str(path), "log", "-1", "--format=%s")
                if parent != ref or subject != f"chore(release): term-mesh@{state['version']}":
                    raise ReleaseError(f"release worktree contains unexpected commits: {actual}")
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    if artifact:
        run("git", "worktree", "add", "--detach", str(path), ref)
    else:
        branch = state["release_branch"]
        existing = git("branch", "--list", branch)
        if existing:
            raise ReleaseError(f"release branch exists without its expected worktree: {branch}")
        run("git", "worktree", "add", "-b", branch, str(path), ref)
    return path


def branch_worktree(branch: str, *, allow_dirty: bool = False) -> Path:
    rows = git("worktree", "list", "--porcelain").splitlines()
    current: Path | None = None
    for line in rows:
        if line.startswith("worktree "):
            current = Path(line.removeprefix("worktree "))
        elif line == f"branch refs/heads/{branch}" and current is not None:
            if not allow_dirty and git("-C", str(current), "status", "--porcelain"):
                raise ReleaseError(f"{branch} worktree is dirty: {current}")
            return current
    path = RELEASE_WORKTREES / branch
    if path.exists():
        raise ReleaseError(f"unregistered path blocks {branch} worktree: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    run("git", "worktree", "add", str(path), branch)
    return path


def remove_worktree(path: Path) -> bool:
    """Drop a release checkout. --force is required: the tree carries the ghostty submodule."""
    if not path.exists():
        return False
    run("git", "worktree", "remove", "--force", str(path), check=False)
    if path.exists():
        shutil.rmtree(path, ignore_errors=True)
    run("git", "worktree", "prune", check=False)
    return not path.exists()


def obsolete_release_worktrees(version: str) -> list[Path]:
    """Release checkouts for this version and older ones.

    A newer version can be releasing concurrently under its own lock, so anything
    above the current version stays. branch_worktree parks a plain `develop`
    checkout in the same directory; the name pattern skips it.
    """
    if not RELEASE_WORKTREES.is_dir():
        return []
    ceiling = tuple(int(part) for part in version.split("."))
    found = []
    for path in sorted(RELEASE_WORKTREES.iterdir()):
        if not path.is_dir():
            continue
        name = RELEASE_WORKTREE_NAME.match(path.name)
        if name and tuple(int(part) for part in name.group(1).split(".")) <= ceiling:
            found.append(path)
    return found


def obsolete_release_branches(version: str) -> list[str]:
    """Local release branches whose tag already shipped.

    The release PR is squash-merged with --delete-branch, so the local branch holds a
    commit no longer reachable from main and release_worktree refuses to run again
    while it exists.
    """
    ceiling = tuple(int(part) for part in version.split("."))
    found = []
    for name in git("branch", "--list", "chore/release-v*", "--format=%(refname:short)").split():
        candidate = name.removeprefix("chore/release-v")
        if not re.fullmatch(r"\d+\.\d+\.\d+", candidate):
            continue
        if tuple(int(part) for part in candidate.split(".")) > ceiling:
            continue
        if git("tag", "-l", f"v{candidate}"):
            found.append(name)
    return found


def cleanup(state: dict[str, Any], *, keep_worktrees: bool) -> None:
    """Reclaim the release checkouts once verify passed.

    Each release parks a source and an artifact worktree under RELEASE_WORKTREES,
    roughly 725MB per version, and nothing ever removed them.
    """
    if keep_worktrees:
        mark(state, "cleanup", skipped="--keep-worktrees")
        return
    worktrees = [str(path) for path in obsolete_release_worktrees(state["version"]) if remove_worktree(path)]
    branches = []
    for name in obsolete_release_branches(state["version"]):
        run("git", "branch", "-D", name)
        branches.append(name)
    mark(state, "cleanup", worktrees=worktrees, branches=branches)


def install_notes(changelog: Path, version: str, notes: str) -> None:
    heading = f"## [{version}]"
    body = changelog.read_text()
    if heading in body:
        return
    if not notes.lstrip().startswith(heading):
        raise ReleaseError(f"notes must start with {heading}")
    marker = "## [Unreleased]"
    if marker not in body:
        raise ReleaseError("CHANGELOG.md has no Unreleased heading")
    changelog.write_text(body.replace(marker, marker + "\n\n" + notes.strip(), 1) + ("" if body.endswith("\n") else "\n"))


def prepare(args: argparse.Namespace) -> dict[str, Any]:
    ensure_approved(args)
    state = load_state(normalize_version(args.version))
    if relay_e2e_required_for_paths(candidate_changed_paths(state)):
        require_relay_e2e_receipt(state, args.relay_e2e_receipt)
    if args.notes_file:
        state["notes"] = Path(args.notes_file).read_text()
        save_state(state)
    if not state.get("notes"):
        raise ReleaseError("prepare requires --notes-file once; notes are then stored for resume")
    merge_develop_to_main(state)
    main_sha = state["steps"]["develop_to_main"]["main_sha"]
    wt = None if completed(state, "release_metadata") else release_worktree(state, main_sha)
    if not completed(state, "release_metadata"):
        begin(state, "release_metadata")
        fetch()
        if remote_sha("main") != main_sha:
            raise ReleaseError("origin/main changed after develop integration; rerun plan --reset before metadata")
        run("./scripts/setup.sh", cwd=wt)
        install_notes(wt / "CHANGELOG.md", state["version"], state["notes"])
        project_version = re.search(
            r"MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+);",
            (wt / "GhosttyTabs.xcodeproj/project.pbxproj").read_text(),
        )
        if not project_version or project_version.group(1) != state["version"]:
            run("./scripts/bump-version.sh", state["version"], cwd=wt)
        version_count = int(run("grep", "-c", f"MARKETING_VERSION = {state['version']}",
                                "GhosttyTabs.xcodeproj/project.pbxproj", cwd=wt))
        if version_count < 4:
            raise ReleaseError("Xcode marketing version verification failed")
        files = ["CHANGELOG.md", "GhosttyTabs.xcodeproj/project.pbxproj", "daemon/Cargo.lock",
                 "daemon/term-mesh-cli/Cargo.toml", "daemon/term-meshd/Cargo.toml"]
        if git("-C", str(wt), "status", "--porcelain"):
            commit_plan = {"commits": [{"message": f"chore(release): term-mesh@{state['version']}", "files": files}]}
            gk("commit", "--plan", "-", cwd=wt, input_text=json.dumps(commit_plan))
        elif f"term-mesh@{state['version']}" not in git("-C", str(wt), "log", "-1", "--format=%s"):
            raise ReleaseError("release metadata is clean but the release commit is missing")
        run("bash", "scripts/test-ghostty-kit-guard.sh", cwd=wt)
        run("xcodebuild", "-project", "GhosttyTabs.xcodeproj", "-scheme", "term-mesh",
            "-configuration", "Debug", "-destination", "platform=macOS", "build", cwd=wt)
        run("cargo", "build", "--release", cwd=wt / "daemon")
        run("git", "diff", "--check", cwd=wt)
        gk("push", cwd=wt)
        mark(state, "release_metadata", branch=state["release_branch"], commit=git("-C", str(wt), "rev-parse", "HEAD"), worktree=str(wt))
    if not completed(state, "release_pr"):
        begin(state, "release_pr")
        fetch()
        if remote_sha("main") != main_sha:
            raise ReleaseError("origin/main changed before release PR creation")
        pr = find_pr(state["release_branch"], "main")
        if pr is None:
            url = run("gh", "pr", "create", "--repo", REPO, "--base", "main", "--head", state["release_branch"],
                      "--title", f"Release v{state['version']}", "--body", state["notes"])
            pr = int(url.rsplit("/", 1)[-1])
        mark(state, "release_pr", pr=pr, url=f"https://github.com/{REPO}/pull/{pr}")
    return state


def publish(args: argparse.Namespace) -> dict[str, Any]:
    ensure_approved(args)
    state = load_state(normalize_version(args.version))
    if not completed(state, "release_pr"):
        raise ReleaseError("release is not prepared; run prepare first")
    pr = state["steps"]["release_pr"]["pr"]
    if not completed(state, "release_merge"):
        begin(state, "release_merge")
        info = gh_json("api", f"repos/{REPO}/pulls/{pr}")
        if not info["merged"]:
            run("gh", "pr", "merge", str(pr), "--repo", REPO, "--squash", "--delete-branch")
            info = gh_json("api", f"repos/{REPO}/pulls/{pr}")
        merge_sha = info["merge_commit_sha"]
        mark(state, "release_merge", merge_sha=merge_sha)
    merge_sha = state["steps"]["release_merge"]["merge_sha"]
    tag = f"v{state['version']}"
    if not completed(state, "tag"):
        begin(state, "tag")
        fetch()
        existing = git("tag", "-l", tag)
        if existing and git("rev-list", "-n1", tag) != merge_sha:
            raise ReleaseError(f"{tag} points at the wrong commit")
        if not existing:
            run("git", "tag", "-a", tag, merge_sha, "-m", f"term-mesh {tag}")
        remote_tag = git("ls-remote", "origin", f"refs/tags/{tag}^{{}}")
        if remote_tag and remote_tag.split()[0] != merge_sha:
            raise ReleaseError(f"origin/{tag} points at the wrong commit")
        if not remote_tag:
            run("git", "push", "origin", tag)
        mark(state, "tag", tag=tag, commit=merge_sha)
    artifact_steps = ("release_build", "dsym", "dmg", "github_release", "homebrew")
    artifact_wt = (
        release_worktree(state, merge_sha, artifact=True)
        if any(not completed(state, name) for name in artifact_steps)
        else None
    )
    if not completed(state, "release_build"):
        begin(state, "release_build")
        derived = Path("/tmp") / f"term-mesh-release-{state['version']}"
        product = derived / "Build/Products/Release/term-mesh.app"
        dsym = Path(str(product) + ".dSYM")
        if not valid_release_product(product, dsym, state["version"], merge_sha):
            run("./scripts/setup.sh", cwd=artifact_wt)
            run("make", "prod", "SENTRY_UPLOAD_DSYM=0", f"PROD_DERIVED_DATA={derived}", cwd=artifact_wt)
        if not valid_release_product(product, dsym, state["version"], merge_sha):
            raise ReleaseError("Release app or dSYM failed version/UUID verification")
        mark(state, "release_build", worktree=str(artifact_wt), app=str(product), dsym=str(dsym), derived_data=str(derived))
    dsym = Path(state["steps"]["release_build"]["dsym"])
    if not completed(state, "dsym"):
        begin(state, "dsym")
        run("./scripts/upload-dsym.sh", str(dsym), cwd=artifact_wt)
        mark(state, "dsym", path=str(dsym))
    if not completed(state, "dmg"):
        begin(state, "dmg")
        derived = state["steps"]["release_build"]["derived_data"]
        run("make", "dmg-package", f"PROD_DERIVED_DATA={derived}", cwd=artifact_wt)
        dmg = artifact_wt / f"term-mesh-macos-{state['version']}.dmg"
        if not dmg.exists():
            raise ReleaseError(f"DMG missing: {dmg}")
        mark(state, "dmg", path=str(dmg), sha256=run("shasum", "-a", "256", str(dmg)).split()[0])
    dmg = state["steps"]["dmg"]["path"]
    if not completed(state, "github_release"):
        begin(state, "github_release")
        run("./scripts/publish-github-release.sh", state["version"], dmg, cwd=artifact_wt)
        mark(state, "github_release", url=f"https://github.com/{REPO}/releases/tag/{tag}")
    if not completed(state, "homebrew"):
        begin(state, "homebrew")
        expected_sha = state["steps"]["dmg"]["sha256"]
        if homebrew_cask() != (state["version"], expected_sha):
            run("./scripts/update-homebrew-cask.sh", state["version"], dmg, cwd=artifact_wt)
        if homebrew_cask() != (state["version"], expected_sha):
            raise ReleaseError("Homebrew cask does not match the published DMG")
        mark(state, "homebrew", version=state["version"], sha256=expected_sha)
    if not completed(state, "develop_resync"):
        begin(state, "develop_resync")
        fetch()
        current_develop = remote_sha("develop")
        if current_develop == merge_sha:
            mark(state, "develop_resync", develop_sha=current_develop, adopted=True)
        elif current_develop != state["candidate_develop_sha"]:
            raise ReleaseError("origin/develop changed during release; refusing automatic resync")
        else:
            develop_wt = branch_worktree("develop", allow_dirty=True)
            gk("pull", cwd=develop_wt)
            gk(
                "merge", "--no-ai", "--autostash",
                "origin/main", "--into", "develop", cwd=develop_wt,
            )
            gk("push", "--from", "develop", cwd=develop_wt)
            fetch()
            mark(state, "develop_resync", develop_sha=remote_sha("develop"), adopted=False)
    if not completed(state, "verify"):
        begin(state, "verify")
        fetch()
        main_sha = remote_sha("main")
        develop_sha = remote_sha("develop")
        if main_sha != merge_sha or develop_sha != merge_sha:
            raise ReleaseError(f"branch mismatch: main={main_sha} develop={develop_sha} release={merge_sha}")
        required = {f"term-mesh-macos-{state['version']}.dmg", "term-meshd-linux-aarch64.tar.gz", "term-meshd-linux-x86_64.tar.gz"}
        deadline = time.monotonic() + 1200
        while True:
            release = gh_json("release", "view", tag, "--repo", REPO, "--json", "url,isDraft,isPrerelease,assets")
            assets = [item["name"] for item in release["assets"]]
            runs = gh_json("run", "list", "--repo", REPO, "--workflow", "release-linux.yml",
                           "--commit", merge_sha, "--event", "push", "--limit", "1",
                           "--json", "status,conclusion,url")
            run_receipt = runs[0] if runs else None
            if (
                required.issubset(assets)
                and not release["isDraft"]
                and not release["isPrerelease"]
                and run_receipt is not None
                and run_receipt["status"] == "completed"
                and run_receipt["conclusion"] == "success"
            ):
                break
            print(f"[release] waiting for Linux assets: {sorted(required - set(assets))}", file=sys.stderr, flush=True)
            if time.monotonic() >= deadline:
                raise ReleaseError(f"release assets incomplete after 20 minutes: {assets}")
            time.sleep(10)
        mark(
            state, "verify", main_sha=main_sha, develop_sha=develop_sha,
            release_url=release["url"], assets=assets, linux_run=run_receipt,
        )
    if not completed(state, "cleanup"):
        begin(state, "cleanup")
        cleanup(state, keep_worktrees=bool(getattr(args, "keep_worktrees", False)))
    return state


def resume(args: argparse.Namespace) -> dict[str, Any]:
    state = load_state(normalize_version(args.version))
    if any(not completed(state, name) for name in ("develop_to_main", "release_metadata", "release_pr")):
        return prepare(args)
    if any(not completed(state, name) for name in STEP_ORDER[3:]):
        state = publish(args)
    return state


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subs = result.add_subparsers(dest="command", required=True)
    p = subs.add_parser("plan")
    p.add_argument("version", nargs="?")
    p.add_argument("--reset", action="store_true")
    p.add_argument("--json", action="store_true")
    for name in ("prepare", "publish", "resume"):
        sub = subs.add_parser(name)
        sub.add_argument("version")
        sub.add_argument("--yes", action="store_true")
        sub.add_argument("--json", action="store_true")
        if name in ("prepare", "resume"):
            sub.add_argument("--notes-file")
            sub.add_argument("--relay-e2e-receipt")
        if name in ("publish", "resume"):
            sub.add_argument("--keep-worktrees", action="store_true")
    s = subs.add_parser("status")
    s.add_argument("version")
    s.add_argument("--json", action="store_true")
    return result


def main() -> int:
    args = parser().parse_args()
    acquired = False
    try:
        requested = (
            "auto"
            if args.command == "plan"
            else normalize_version(args.version)
        )
        with release_lock(requested):
            acquired = True
            if args.command == "plan":
                state = plan(args)
            elif args.command == "prepare":
                state = prepare(args)
            elif args.command == "publish":
                state = publish(args)
            elif args.command == "resume":
                state = resume(args)
            else:
                state = load_state(normalize_version(args.version))
        emit(state, command=args.command)
        return 0
    except ReleaseError as exc:
        if acquired and getattr(args, "version", None):
            record_failure(normalize_version(args.version), str(exc))
        print(json.dumps({"schema": 1, "state": "blocked", "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
