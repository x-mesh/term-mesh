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
    # The relay helper carries every keystroke and every byte of PTY output on
    # a remote pane. v0.217.0 changed its stdin teardown with this gate not
    # firing, because the list had the daemon's peer module but not the helper
    # that talks to it.
    "daemon/term-mesh-peer-relay/",
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
        "reconciled": {
            name: state["steps"][name]["reconciled_from"]
            for name in STEP_ORDER
            if "reconciled_from" in state["steps"][name]
        },
        "interrupted": [
            name for name in STEP_ORDER
            if state["steps"][name].get("status") == "interrupted"
        ],
        # Only for stages still outstanding. The observation is taken once, at
        # load; a stage that has completed since has resolved whatever its
        # mismatch was, and printing it beside "state": "complete" reads as an
        # unresolved problem.
        "mismatched": [
            entry["detail"]
            for entry in state.get("observation", {}).get("mismatched", [])
            # A receipt written before mismatches carried their stage holds
            # plain strings. Reporting one is right; crashing on it is not.
            if isinstance(entry, dict) and not completed(state, entry["step"])
        ] + [
            entry
            for entry in state.get("observation", {}).get("mismatched", [])
            if isinstance(entry, str)
        ],
        "unread_remote_facts": state.get("observation", {}).get("unreadable", {}),
        "receipts": state["steps"],
    }, indent=2, ensure_ascii=False))


# What `gh` prints when the thing asked for is not there. Measured, not
# assumed: a missing release prints `release not found`, and `gh api` prints
# `Not Found (HTTP 404)`.
GH_ABSENT = ("not found", "http 404")


def gh_failure_reason(detail: str, repo: str) -> str | None:
    """None when a `gh` failure means the resource is absent, else the message.

    The text alone cannot decide this. GitHub answers 404 for a repository the
    token cannot see, so a revoked or scope-reduced token prints exactly what a
    missing release prints — matching on the message was the whole bug. A
    not-found answer is only credible as absence when the repository itself
    still reads, so that is asked, once, on that path only.
    """
    if not detail:
        # An empty message is still a failure, and an empty string is falsy —
        # the absence/failure collapse this function exists to remove.
        return "gh failed without output"
    if not any(pattern in detail.lower() for pattern in GH_ABSENT):
        return detail
    if repo_is_readable(repo):
        return None
    return f"{detail} (and {repo} does not read, so this is access, not absence)"


def repo_is_readable(repo: str) -> bool:
    """Whether this token can see `repo` at all."""
    proc = subprocess.run(
        ("gh", "api", f"repos/{repo}", "--jq", ".name"),
        cwd=ROOT, text=True, capture_output=True, check=False,
    )
    return proc.returncode == 0


def gh_text_optional(*args: str, repo: str = REPO) -> tuple[str | None, str | None]:
    """Read a plain-text `gh` fact, splitting absence from failure.

    `repo` names the repository the call reads, which is what a not-found
    answer is checked against.
    """
    proc = subprocess.run(("gh", *args), cwd=ROOT, text=True, capture_output=True, check=False)
    if proc.returncode == 0:
        return proc.stdout.strip(), None
    return None, gh_failure_reason((proc.stderr or proc.stdout).strip(), repo)


def gh_json_optional(*args: str, repo: str = REPO) -> tuple[Any, str | None]:
    """Read a `gh` fact that may legitimately not exist yet.

    Returns `(value, error)`. A resource that is absent yields `(None, None)`,
    because "no release for this tag" is a fact. Anything else yields
    `(None, message)`, so an unreachable `gh` is reported as an unread fact
    instead of being mistaken for absence.
    """
    raw, error = gh_text_optional(*args, repo=repo)
    if error or not raw:
        return None, error
    return json.loads(raw), None


def release_assets(tag: str) -> list[str]:
    """Asset names currently attached to a tag's GitHub Release.

    A read that fails is raised, never returned as an empty list. This feeds
    the retention check either side of the DMG upload, and an empty list there
    is wrong in both directions: before the upload it leaves nothing to retain,
    so a real asset loss passes; after it, every asset reads as dropped and a
    release that succeeded fails on an invented loss. A tag with no release at
    all still answers honestly with an empty list.
    """
    release, error = gh_json_optional("release", "view", tag, "--repo", REPO, "--json", "assets")
    if error:
        raise ReleaseError(f"could not read the assets on {tag}: {error}")
    return [item["name"] for item in (release or {}).get("assets", [])]


def upload_release_dmg(version: str, tag: str, dmg: str, cwd: Path) -> tuple[list[str], list[str]]:
    """Attach the DMG to a tag's release without losing what is already there.

    The Linux workflow publishes from the tag push, so its archives can already
    be attached when the macOS stages run. Uploading the DMG must add to that
    release. Returns the published and the pre-existing asset names.
    """
    retained = {name for name in release_assets(tag) if not name.endswith(".dmg")}
    run("./scripts/publish-github-release.sh", version, dmg, cwd=cwd)
    published = set(release_assets(tag))
    lost = sorted(retained - published)
    if lost:
        raise ReleaseError(f"publishing the DMG dropped existing release assets: {lost}")
    return sorted(published), sorted(retained)


def observe(state: dict[str, Any]) -> dict[str, Any]:
    """Read the remote facts this release's receipt can be checked against.

    A release can stop between a remote mutation and the receipt that records
    it, so resume has to ask the remote what already happened. Every read here
    is idempotent, and no read may fail the command: a release must stay
    inspectable when `gh` is unreachable, so an unread fact stays None and is
    reported.
    """
    tag = f"v{state['version']}"
    facts: dict[str, Any] = {
        "tag": tag,
        "tag_commit": None,
        "release": None,
        "homebrew": None,
        "mismatched": [],
        "unreadable": {},
    }
    try:
        line = git("ls-remote", "origin", f"refs/tags/{tag}^{{}}")
        facts["tag_commit"] = line.split()[0] if line else None
    except ReleaseError as exc:
        facts["unreadable"]["tag_commit"] = str(exc)
    release, error = gh_json_optional(
        "release", "view", tag, "--repo", REPO, "--json", "url,isDraft,isPrerelease,assets"
    )
    if error:
        facts["unreadable"]["release"] = error
    else:
        facts["release"] = release
    facts["homebrew"], homebrew_error = homebrew_cask_reading()
    if homebrew_error:
        facts["unreadable"]["homebrew"] = homebrew_error
    return facts


def reconcile(state: dict[str, Any], facts: dict[str, Any]) -> dict[str, Any]:
    """Fold observed remote state into a receipt that fell behind it.

    v0.226.4 stopped with `release_build` still marked `running` while its tag
    and its Linux assets were already public. Resuming that receipt would have
    re-run stages the remote had already finished, and reading it gave no sign
    that the remote had moved on. A stage is adopted here only when a remote
    fact proves it, and the proof goes into the receipt.

    Local artifact stages (`release_build`, `dsym`, `dmg`) are never adopted
    from the remote: the DMG's checksum is what Homebrew publishes, so a stage
    that produced it must have a local receipt or run again.
    """
    version = state["version"]
    tag = facts["tag"]

    # main() holds this version's exclusive lock, so no other release process
    # owns this receipt. A stage still marked `running` was interrupted, and
    # saying so is what separates "in flight" from "abandoned".
    for name in STEP_ORDER:
        if state["steps"][name].get("status") == "running":
            state["steps"][name] = {
                **state["steps"][name],
                "status": "interrupted",
                "interrupted_at": utc_now(),
            }
            save_state(state)

    if completed(state, "release_pr") and not completed(state, "release_merge"):
        pr = state["steps"]["release_pr"]["pr"]
        info, error = gh_json_optional("api", f"repos/{REPO}/pulls/{pr}")
        if error:
            facts["unreadable"]["release_pr"] = error
        elif info and info.get("merged"):
            mark(state, "release_merge", merge_sha=info["merge_commit_sha"],
                 reconciled_from=f"pull {pr} is already merged")

    merge_sha = state["steps"]["release_merge"].get("merge_sha")
    if merge_sha and facts["tag_commit"] and not completed(state, "tag"):
        if facts["tag_commit"] == merge_sha:
            mark(state, "tag", tag=tag, commit=merge_sha,
                 reconciled_from=f"origin already holds {tag}")
        else:
            facts["mismatched"].append({
                "step": "tag",
                "detail": f"origin {tag} points at {facts['tag_commit'][:12]}, "
                          f"not the release commit {merge_sha[:12]}",
            })

    # `release` stays None when the read failed, and the reconciliation below
    # cannot tell that from "no release yet" — so it does not try. The failure
    # is already reported under `unreadable`, and adopting nothing is the safe
    # direction: the stage runs again rather than being skipped on a guess.
    release = facts["release"] if "release" not in facts["unreadable"] else None
    dmg_asset = f"term-mesh-macos-{version}.dmg"
    if release and not completed(state, "github_release"):
        assets = [item["name"] for item in release.get("assets", [])]
        # The Linux workflow publishes from the tag push, so a release can be
        # public with only its Linux assets. That is not this stage: adopt it
        # only once the macOS DMG this release built is the one attached.
        if dmg_asset in assets and completed(state, "dmg"):
            mark(state, "github_release", url=release["url"], assets=sorted(assets),
                 reconciled_from=f"{dmg_asset} is already published")
        elif dmg_asset in assets:
            facts["mismatched"].append({
                "step": "github_release",
                "detail": f"{dmg_asset} is published on {release['url']} but no local "
                          "dmg receipt records its checksum; the stage runs again and "
                          "replaces that asset from the pinned release commit",
            })

    if completed(state, "dmg") and not completed(state, "homebrew"):
        expected = (version, state["steps"]["dmg"]["sha256"])
        if facts["homebrew"] is not None and tuple(facts["homebrew"]) == expected:
            mark(state, "homebrew", version=version, sha256=expected[1],
                 reconciled_from="the cask already points at the published DMG")

    state["observation"] = {
        "observed_at": utc_now(),
        "tag_commit": facts["tag_commit"],
        "release_assets": sorted(
            item["name"] for item in (facts["release"] or {}).get("assets", [])
        ),
        "homebrew": list(facts["homebrew"]) if facts["homebrew"] else None,
        "mismatched": facts["mismatched"],
        "unreadable": facts["unreadable"],
    }
    save_state(state)
    return facts


def load_reconciled(version: str) -> dict[str, Any]:
    """Load a receipt and bring it up to date with what the remote already has."""
    state = load_state(version)
    reconcile(state, observe(state))
    return state


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


def homebrew_cask_reading() -> tuple[tuple[str, str] | None, str | None]:
    """The cask's `(version, sha256)`, and why it could not be read.

    Kept apart from `homebrew_cask` because `observe` has to tell "the cask
    says 0.226.3" from "nobody could read the cask" — the same distinction
    every other read there makes, and the one this function used to collapse
    by answering None for both.
    """
    content, error = gh_text_optional(
        "api", "repos/x-mesh/homebrew-tap/contents/Casks/term-mesh.rb?ref=main", "--jq", ".content",
        repo="x-mesh/homebrew-tap",
    )
    if error:
        return None, error
    if not content:
        return None, None
    try:
        body = base64.b64decode(content).decode()
    except (ValueError, UnicodeDecodeError) as exc:
        return None, f"cask content is not readable: {exc}"
    version = re.search(r'^  version "([^"]+)"$', body, re.M)
    sha = re.search(r'^  sha256 "([0-9a-f]{64})"$', body, re.M)
    if not (version and sha):
        return None, "cask has no version/sha256 pair"
    return (version.group(1), sha.group(1)), None


def homebrew_cask() -> tuple[str, str] | None:
    """The published cask, or None. Callers that only compare it for equality
    fail their own step with a clear message, so they do not need the reason."""
    reading, _ = homebrew_cask_reading()
    return reading


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


def keep_marker(path: Path) -> Path:
    """Sidecar that opts a release checkout out of reclamation for good.

    It sits beside the checkout rather than inside it: a file within the worktree
    would make `git status --porcelain` dirty and trip release_worktree's guard.
    Delete the sidecar to hand the checkout back to the next release.
    """
    return path.parent / f".keep-{path.name}"


def registered_worktrees() -> dict[Path, bool]:
    """Every checkout git knows about, mapped to whether it is locked."""
    found: dict[Path, bool] = {}
    current: Path | None = None
    for line in git("worktree", "list", "--porcelain").splitlines():
        if line.startswith("worktree "):
            current = Path(line.removeprefix("worktree "))
            found[current.resolve()] = False
        elif line.startswith("locked") and current is not None:
            found[current.resolve()] = True
    return found


def release_is_running(version: str) -> bool:
    """Whether another process currently holds that version's release lock."""
    path = state_dir() / f"v{version}.lock"
    if not path.exists():
        return False
    with path.open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(handle, fcntl.LOCK_UN)
    return False


def release_is_settled(version: str, current: str) -> bool:
    """Whether a version's release finished, so its checkout is safe to reclaim.

    cleanup runs after verify, so the version being published is settled by
    construction. Every other version has to prove it: an untagged one was abandoned
    before `tag` and still needs its worktree, because release_worktree refuses to
    rebuild a checkout while its branch exists. A tagged one may still be mid-publish
    under its own per-version lock, which does not serialize against this release.
    """
    if version == current:
        return True
    if not git("tag", "-l", f"v{version}"):
        return False
    if release_is_running(version):
        return False
    receipt = release_receipt(version)
    if receipt is None:
        return True
    return receipt.get("steps", {}).get("verify", {}).get("status") == "completed"


def release_receipt(version: str) -> dict[str, Any] | None:
    """That version's state file, or None when it is missing or unreadable."""
    path = state_path(version)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def remove_worktree(path: Path) -> str:
    """Drop a release checkout, reporting which of three outcomes happened.

    Returns "absent", "removed", or "failed" so the caller can tell "nothing to
    reclaim" from "reclaim failed". --force is required: the tree carries the
    ghostty submodule. The rmtree fallback only covers a directory git does not
    know about; a registered checkout git refused to drop is reported, never forced.
    """
    if not path.exists():
        return "absent"
    run("git", "worktree", "remove", "--force", str(path), check=False)
    if path.exists():
        if path.resolve() in registered_worktrees():
            return "failed"
        shutil.rmtree(path, ignore_errors=True)
    run("git", "worktree", "prune", check=False)
    return "removed" if not path.exists() else "failed"


def obsolete_release_worktrees(version: str) -> list[Path]:
    """Release checkouts this release may reclaim.

    A checkout is claimed only when its own release is settled, so a concurrent
    publish keeps its tree and an abandoned release keeps the tree its resume needs.
    branch_worktree parks a plain `develop` checkout in the same directory; the name
    pattern skips it. A `.keep-<name>` sidecar or a `git worktree lock` opts a
    checkout out permanently, not just for the release that set it.
    """
    if not RELEASE_WORKTREES.is_dir():
        return []
    ceiling = tuple(int(part) for part in version.split("."))
    locked = {path for path, is_locked in registered_worktrees().items() if is_locked}
    found = []
    for path in sorted(RELEASE_WORKTREES.iterdir()):
        if not path.is_dir() or path.resolve() in locked or keep_marker(path).exists():
            continue
        name = RELEASE_WORKTREE_NAME.match(path.name)
        if not name or tuple(int(part) for part in name.group(1).split(".")) > ceiling:
            continue
        if release_is_settled(name.group(1), version):
            found.append(path)
    return found


def obsolete_release_branches(version: str) -> list[str]:
    """Local release branches whose release shipped and whose tip is what shipped.

    The release PR is squash-merged with --delete-branch, so the local branch holds a
    commit no longer reachable from main and release_worktree refuses to run again
    while it exists. `git branch -d` therefore always refuses and -D is required,
    which leaves the recorded-tip comparison as the only guard against destroying a
    commit added to the branch after its tag.
    """
    ceiling = tuple(int(part) for part in version.split("."))
    kept = (
        {path.name.removeprefix(".keep-") for path in RELEASE_WORKTREES.glob(".keep-*")}
        if RELEASE_WORKTREES.is_dir()
        else set()
    )
    found = []
    for name in git("branch", "--list", "chore/release-v*", "--format=%(refname:short)").split():
        candidate = name.removeprefix("chore/release-v")
        if not re.fullmatch(r"\d+\.\d+\.\d+", candidate):
            continue
        if tuple(int(part) for part in candidate.split(".")) > ceiling:
            continue
        if f"v{candidate}-source" in kept:
            continue
        if not release_is_settled(candidate, version):
            continue
        receipt = release_receipt(candidate) or {}
        shipped = receipt.get("steps", {}).get("release_metadata", {}).get("commit")
        if not shipped or git("rev-parse", name) != shipped:
            continue
        found.append(name)
    return found


def cleanup(state: dict[str, Any], *, keep_worktrees: bool) -> None:
    """Reclaim the release checkouts once verify passed.

    Each release parks a source and an artifact worktree under RELEASE_WORKTREES,
    roughly 725MB per version, and nothing ever removed them. This runs after the
    release is provably complete, so nothing here may fail it: every outcome lands
    in the receipt and on stderr instead of raising.
    """
    claimed = obsolete_release_worktrees(state["version"])
    if keep_worktrees:
        prefix = f"v{state['version']}-"
        kept, deferred = [], []
        for path in claimed:
            if not path.name.startswith(prefix):
                deferred.append(str(path))
                continue
            keep_marker(path).write_text(f"kept by release v{state['version']} at {utc_now()}\n")
            kept.append(str(path))
        mark(state, "cleanup", skipped="--keep-worktrees", kept=kept, deferred=deferred)
        return
    worktrees, stuck_worktrees = [], []
    for path in claimed:
        outcome = remove_worktree(path)
        if outcome == "removed":
            worktrees.append(str(path))
        elif outcome == "failed":
            stuck_worktrees.append(str(path))
    branches, stuck_branches = [], []
    for name in obsolete_release_branches(state["version"]):
        run("git", "branch", "-D", name, check=False)
        (stuck_branches if git("branch", "--list", name) else branches).append(name)
    receipt: dict[str, Any] = {"worktrees": worktrees, "branches": branches}
    if stuck_worktrees:
        receipt["failed_worktrees"] = stuck_worktrees
    if stuck_branches:
        receipt["failed_branches"] = stuck_branches
    if stuck_worktrees or stuck_branches:
        print(
            f"[release] cleanup could not reclaim: {stuck_worktrees + stuck_branches}",
            file=sys.stderr, flush=True,
        )
    mark(state, "cleanup", **receipt)


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


def publish(args: argparse.Namespace, state: dict[str, Any] | None = None) -> dict[str, Any]:
    ensure_approved(args)
    # `state` lets resume hand over the receipt it already reconciled. Each
    # reconcile is four remote reads and a write, and running them again would
    # only re-derive what the caller is holding.
    state = load_reconciled(normalize_version(args.version)) if state is None else state
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
        published, retained = upload_release_dmg(state["version"], tag, dmg, artifact_wt)
        mark(state, "github_release", url=f"https://github.com/{REPO}/releases/tag/{tag}",
             assets=published, retained=retained)
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
        cleanup(state, keep_worktrees=args.keep_worktrees)
    return state


def resume(args: argparse.Namespace) -> dict[str, Any]:
    state = load_reconciled(normalize_version(args.version))
    if any(not completed(state, name) for name in ("develop_to_main", "release_metadata", "release_pr")):
        return prepare(args)
    if any(not completed(state, name) for name in STEP_ORDER[3:]):
        state = publish(args, state)
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
                state = load_reconciled(normalize_version(args.version))
        emit(state, command=args.command)
        return 0
    except ReleaseError as exc:
        if acquired and getattr(args, "version", None):
            record_failure(normalize_version(args.version), str(exc))
        print(json.dumps({"schema": 1, "state": "blocked", "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
