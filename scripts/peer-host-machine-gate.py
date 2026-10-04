#!/usr/bin/env python3
"""Mutation gate for PeerHostMachine.

docs/peer-host-registry-redesign.md ("Gate") requires both explorer layers to
pass, and breaking any one of rules 1-8 to make at least one layer fail. Rule 1
(no read-await-write) is structural in a synchronous core, so it is checked by
source inspection; every other rule gets a mutant that must be caught by the
named layer with the named violation tag.

Each mutant edits a source file, runs one explorer test, and restores the
original. The restore is verified byte for byte, also when the run is
interrupted.

Usage: scripts/peer-host-machine-gate.py [--only NAME]
"""

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "swift" / "PeerProto"
SOURCES = PACKAGE / "Sources" / "PeerProto" / "HostMachine"
MACHINE = SOURCES / "PeerHostMachine.swift"
CORE = SOURCES / "PeerHostShellCore.swift"
TEST_CLASS = "PeerHostMachineExplorerTests"
LOG_DIR = Path(tempfile.gettempdir()) / "peer-host-machine-gate"
LAYER1 = "test_layer1_everyStateWithinBoundsHoldsTheInvariants"
LAYER2 = "test_layer2_reentrantCallsDuringEffectsHoldTheInvariants"

MUTANTS = [
    {
        "name": "rule 2: commit after the effects run",
        "file": CORE,
        "old": "        state = after\n        let context = EffectContext(cause: event, before: before)\n"
               "        for effect in effects {\n"
               "            if case let .queueUnusedCheck(lease) = effect {\n"
               "                queue.append(.event(.unusedCheck(lease)))\n"
               "            } else {\n"
               "                perform(effect, context)\n"
               "            }\n"
               "        }\n",
        "new": "        let context = EffectContext(cause: event, before: before)\n"
               "        for effect in effects {\n"
               "            if case let .queueUnusedCheck(lease) = effect {\n"
               "                queue.append(.event(.unusedCheck(lease)))\n"
               "            } else {\n"
               "                perform(effect, context)\n"
               "            }\n"
               "        }\n"
               "        state = after\n",
        "test": LAYER1,
        "tag": "rule 2",
    },
    {
        "name": "rule 2: reduce re-entrant calls in the middle of an effect list",
        "file": CORE,
        "old": "        guard !draining else { return }\n",
        "new": "",
        "test": LAYER2,
        "tag": None,
    },
    {
        "name": "rule 3: sample the verdict when the acquire is raised",
        "file": CORE,
        "old": "        enqueue(.acquire(request))\n",
        "new": "        enqueue(.event(.acquire(request, state.pooledLease.map(sampleVerdict) ?? .usable)))\n",
        "test": LAYER2,
        "tag": "rule 3",
    },
    {
        "name": "rule 4: ignore an acquire raised before a disconnect",
        "file": MACHINE,
        "old": "                return resume(id, .failure(.hostDisconnected))\n",
        "new": "                return\n",
        "test": LAYER1,
        "tag": "rule 4",
    },
    {
        "name": "rule 4: treat a stale token as a plain acquire",
        "file": MACHINE,
        "old": "            if let token = request.token, token != state.reconnectToken {\n"
               "                return resume(id, .failure(.reconnectSuperseded))\n"
               "            }\n",
        "new": "",
        "test": LAYER1,
        "tag": "rule 5",
    },
    {
        "name": "rule 5: let a background waiter start from idle with its own spec",
        "file": MACHINE,
        "old": "                guard request.origin == .user, let spec = request.spec else {\n",
        "new": "                guard let spec = request.spec else {\n",
        "test": LAYER1,
        "tag": "rule 5",
    },
    {
        "name": "rule 6: read dependents after the references leave the pool",
        "file": MACHINE,
        "old": "            let dependents = references > 0 || !state.waiters.isEmpty\n",
        "new": "            let dependents = !state.waiters.isEmpty\n",
        "test": LAYER1,
        "tag": "rule 6",
    },
    {
        "name": "rule 7: a deadline cancels the start",
        "file": MACHINE,
        "old": "            case let .waiterDeadline(waiter):\n"
               "                if removeWaiter(waiter) {\n"
               "                    resume(waiter, .failure(.timedOut))\n"
               "                }\n",
        "new": "            case let .waiterDeadline(waiter):\n"
               "                cancel(waiter)\n",
        "test": LAYER1,
        "tag": "rule 7",
    },
    {
        "name": "rule 7: admit a waiter without a deadline",
        "file": MACHINE,
        "old": "            effects.append(.armWaiterDeadline(waiter.id))\n",
        "new": "",
        "test": LAYER1,
        "tag": "rule 7",
    },
    {
        "name": "rule 8: resume with the pooled lease without counting the reference",
        "file": MACHINE,
        "old": "                    state.phase = .up(lease, spec, refs: refs + 1)\n",
        "new": "                    state.phase = .up(lease, spec, refs: refs)\n",
        "test": LAYER1,
        "tag": "rule 8",
    },
    {
        "name": "park invariant: never abandon an unpayable debt",
        "file": MACHINE,
        "old": "        transition.enforceParkInvariant()\n",
        "new": "",
        "test": LAYER1,
        "tag": "parked forever",
    },
    {
        "name": "zero references stop the lease at once instead of through the queue",
        "file": MACHINE,
        "old": "                state.phase = .up(lease, spec, refs: remaining)\n"
               "                if remaining == 0 {\n"
               "                    effects.append(.queueUnusedCheck(lease))\n"
               "                }\n",
        "new": "                state.phase = .up(lease, spec, refs: remaining)\n"
               "                if remaining == 0 {\n"
               "                    state.phase = .idle\n"
               "                    effects.append(.stopTunnel(lease))\n"
               "                }\n",
        "test": LAYER2,
        "tag": "parked forever",
    },
]


def run_test(test, log=None):
    command = [
        "swift", "test", "-c", "release", "-Xswiftc", "-enable-testing",
        "--package-path", str(PACKAGE), "--filter", f"{TEST_CLASS}/{test}",
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    output = result.stdout + result.stderr
    if log is not None:
        log.write_text(output)
    executed = re.search(r"Executed 1 test, with (\d+) failures?", output)
    explorer = [line for line in output.splitlines() if line.startswith("[explorer]")]
    tags = []
    if explorer:
        found = re.search(r"violations: (.*)$", explorer[-1])
        if found and found.group(1) != "none":
            tags = [tag.strip() for tag in found.group(1).split(",")]
    return {
        "ran": executed is not None,
        "failures": int(executed.group(1)) if executed else None,
        "summary": explorer[-1] if explorer else "(no explorer summary)",
        "tags": tags,
        "build_failed": "error:" in output and executed is None,
        "output": output,
    }


def check_rule1():
    problems = []
    for path in (MACHINE, CORE):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            code = line.split("//")[0]
            if re.search(r"\b(async|await|Task|DispatchQueue|Thread)\b", code):
                problems.append(f"{path.name}:{number}: {line.strip()}")
    if "public static func reduce(" not in MACHINE.read_text():
        problems.append("PeerHostMachine.reduce is not a static function")
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="run only mutants whose name contains this text")
    args = parser.parse_args()

    failed = False
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    print(f"logs: {LOG_DIR}")
    problems = check_rule1()
    print(f"rule 1 (structural): {'ok' if not problems else 'FAILED'}")
    for problem in problems:
        print(f"  {problem}")
    failed |= bool(problems)

    for test in (LAYER1, LAYER2):
        result = run_test(test)
        clean = result["ran"] and result["failures"] == 0
        print(f"baseline {test}: {'ok' if clean else 'FAILED'}  {result['summary']}")
        if not clean:
            print(result["output"][-4000:])
            return 1

    backup_dir = Path(tempfile.mkdtemp(prefix="peer-host-gate-"))
    originals = {path: backup_dir / path.name for path in (MACHINE, CORE)}
    for path, copy in originals.items():
        shutil.copy2(path, copy)

    def restore():
        for path, copy in originals.items():
            shutil.copy2(copy, path)
            if path.read_bytes() != copy.read_bytes():
                raise SystemExit(f"restore of {path} did not match the original")

    try:
        for mutant in MUTANTS:
            if args.only and args.only not in mutant["name"]:
                continue
            source = mutant["file"].read_text()
            if source.count(mutant["old"]) != 1:
                print(f"MUTANT DID NOT APPLY: {mutant['name']}")
                failed = True
                continue
            mutant["file"].write_text(source.replace(mutant["old"], mutant["new"]))
            log = LOG_DIR / (re.sub(r"[^a-z0-9]+", "-", mutant["name"].lower()).strip("-") + ".log")
            try:
                result = run_test(mutant["test"], log)
            finally:
                restore()
            layer = "layer 1" if mutant["test"] == LAYER1 else "layer 2"
            caught = result["ran"] and (result["failures"] or 0) > 0
            if mutant["tag"] is not None:
                caught = caught and mutant["tag"] in result["tags"]
            status = "caught" if caught else "SURVIVED"
            if result["build_failed"]:
                status = "BUILD FAILED"
                caught = False
            print(f"{status:12} {mutant['name']}  [{layer}; failures: {result['failures']}; "
                  f"violations: {', '.join(result['tags']) or 'none'}]", flush=True)
            failed |= not caught
    finally:
        restore()
        shutil.rmtree(backup_dir, ignore_errors=True)

    print("gate:", "FAILED" if failed else "passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
