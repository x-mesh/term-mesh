#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/daemon/term-meshd/tests/fixtures/security_faults.json"
REPORT="${TMPDIR:-/tmp}/term-mesh-security-fault-report.json"

if [[ "${1:-}" == "--report" ]]; then
  [[ -n "${2:-}" ]] || { echo "--report requires a path" >&2; exit 2; }
  REPORT="$2"
fi

python3 - "$ROOT" "$FIXTURE" "$REPORT" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys
import time

root = pathlib.Path(sys.argv[1])
fixture_path = pathlib.Path(sys.argv[2])
report_path = pathlib.Path(sys.argv[3])
fixture_bytes = fixture_path.read_bytes()
fixture = json.loads(fixture_bytes)
results = []
started = time.monotonic()

for case in fixture["cases"]:
    command = [
        "cargo", "test", "-p", case["package"], "--test", case["target"],
        case["filter"], "--", "--exact",
    ]
    case_started = time.monotonic()
    completed = subprocess.run(
        command,
        cwd=root / "daemon",
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    output = completed.stdout.encode()
    results.append({
        "id": case["id"],
        "domain": case["domain"],
        "threats": case["threats"],
        "invariant": case["invariant"],
        "passed": completed.returncode == 0,
        "duration_ms": round((time.monotonic() - case_started) * 1000),
        "output_sha256": hashlib.sha256(output).hexdigest(),
        "output_tail": completed.stdout.splitlines()[-8:],
    })

passed = sum(1 for result in results if result["passed"])
core = {
    "schema": 1,
    "suite": fixture["suite"],
    "fixture_sha256": hashlib.sha256(fixture_bytes).hexdigest(),
    "total": len(results),
    "passed": passed,
    "failed": len(results) - passed,
    "duration_ms": round((time.monotonic() - started) * 1000),
    "threats_exercised": sorted({t for result in results for t in result["threats"]}),
    "results": results,
}
canonical = json.dumps(core, sort_keys=True, separators=(",", ":")).encode()
core["report_integrity_sha256"] = hashlib.sha256(canonical).hexdigest()
report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(json.dumps(core, indent=2, sort_keys=True) + "\n")
print(f"security fault suite: {passed}/{len(results)} passed")
print(f"report: {report_path}")
print(f"integrity: {core['report_integrity_sha256']}")
if passed != len(results):
    for result in results:
        if not result["passed"]:
            print(f"FAILED {result['id']}: {' | '.join(result['output_tail'])}", file=sys.stderr)
    sys.exit(1)
PY
