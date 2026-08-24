#!/bin/sh
# Verify leader turn logging, correlation, payload transports, and privacy.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOOK="$ROOT/scripts/leader-turn-hook.sh"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/term-mesh-turn-hook.XXXXXX") || exit 1
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

run_hook() {
    HOME="$TEST_TMP/home" \
        TERMMESH_TEAM=turn-test \
        TERMMESH_SURFACE_ID=11111111-2222-3333-4444-555555555555 \
        TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token \
        "$HOOK" "$@"
}

mkdir -p "$TEST_TMP/home" || exit 1
LOG="$TEST_TMP/home/.term-mesh/logs/turns.log"

# Worker panes have TERMMESH_TEAM but no leader request token; they must have
# zero observable effect.
env -u TERMMESH_LEADER_REQUEST_TOKEN HOME="$TEST_TMP/worker" \
    TERMMESH_TEAM=turn-test TERMMESH_SURFACE_ID=worker-surface \
    "$HOOK" --start '{"prompt":"ignored"}' \
    >/dev/null 2>&1 || fail "worker gate returned nonzero"
[ ! -e "$TEST_TMP/worker/.term-mesh" ] || fail "worker pane touched the filesystem"

SECRET_STDIN=TURN_HOOK_SECRET_FROM_STDIN
printf '{"session_id":"session-from-root","prompt":"%s"}' "$SECRET_STDIN" | run_hook --start \
    || fail "stdin start failed"
run_hook --end '{"hook_event_name":"Stop","session_id":"session-from-root","stop_hook_active":false}' \
    || fail "argv end failed"

SECRET_ARGV='TURN_HOOK_SECRET_FROM_ARGV_한글'
run_hook --start "{\"data\":{\"sessionId\":\"session-from-nested-data\"},\"prompt\":\"$SECRET_ARGV\"}" \
    || fail "argv start failed"
printf '%s' '{"hook_event_name":"Stop","session_id":"different-stop-value","stop_hook_active":false}' | run_hook --end \
    || fail "stdin end failed"

python3 - "$LOG" "$SECRET_STDIN" "$SECRET_ARGV" \
    session-from-root session-from-nested-data <<'PY' || exit 1
import json
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
raw = path.read_text(encoding="utf-8")
for secret in sys.argv[2:]:
    if secret in raw:
        raise SystemExit(f"FAIL: prompt content leaked: {secret}")
lines = [json.loads(line) for line in raw.splitlines()]
if len(lines) != 4:
    raise SystemExit(f"FAIL: expected four lines, got {len(lines)}")
for offset in (0, 2):
    start, end = lines[offset:offset + 2]
    if start["event"] != "turn_start" or end["event"] != "turn_end":
        raise SystemExit("FAIL: wrong event ordering")
    if start["turn_id"] != end["turn_id"] or start["turn_id"] == "unknown":
        raise SystemExit("FAIL: start/end turn IDs do not correlate")
    if len(start["turn_id"]) != 16:
        raise SystemExit("FAIL: turn ID is not 16 hex characters")
    prompt = sys.argv[2 + offset // 2]
    session_id = sys.argv[4 + offset // 2]
    expected_prompt_sha = hashlib.sha256(prompt.encode()).hexdigest()
    expected_turn_id = hashlib.sha256(
        f'{session_id}:{expected_prompt_sha}'.encode()
    ).hexdigest()[:16]
    if start["turn_id"] != expected_turn_id:
        raise SystemExit("FAIL: turn ID does not match the specified derivation")
    if start["prompt_bytes"] != len(prompt.encode()):
        raise SystemExit("FAIL: wrong prompt byte count")
    if start["prompt_sha256"] != expected_prompt_sha:
        raise SystemExit("FAIL: wrong prompt SHA-256")
PY

# Route status is an outcome, not a reconstruction from timestamps. A stated
# route leaves a short-lived per-turn marker; Stop consumes it and records the
# outcome on the matching end record. The first turn intentionally has no
# marker and therefore proves the denominator's `unstated` branch.
first_turn=$(python3 - "$LOG" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text().splitlines()[0])["turn_id"])
PY
)
second_turn=$(python3 - "$LOG" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text().splitlines()[2])["turn_id"])
PY
)
python3 - "$LOG" "$first_turn" "$second_turn" <<'PY' || exit 1
import json, pathlib, sys
records = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
ends = {record["turn_id"]: record for record in records if record["event"] == "turn_end"}
if ends[sys.argv[2]].get("route_status") != "unstated":
    raise SystemExit("FAIL: end without a route marker was not unstated")
if ends[sys.argv[3]].get("route_status") != "unstated":
    raise SystemExit("FAIL: unmarked end was not unstated")
PY

# With all three hash implementations hidden, start still records a line and
# explicitly marks the digest unavailable. Provide only the POSIX tools the
# hook needs through a controlled PATH.
FAKE_BIN="$TEST_TMP/no-hash-bin"
mkdir -p "$FAKE_BIN" || exit 1
for tool in mkdir date tr mv rm cat; do
    tool_path=$(command -v "$tool") || fail "missing test prerequisite: $tool"
    ln -s "$tool_path" "$FAKE_BIN/$tool" || exit 1
done
HOME="$TEST_TMP/home" PATH="$FAKE_BIN" TERMMESH_TEAM=turn-test \
    TERMMESH_SURFACE_ID=no-hash-surface TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token \
    "$HOOK" --start '{"prompt":"HASH_TOOL_SECRET"}' \
    || fail "missing hash tools returned nonzero"

# Malformed and empty payloads are valid hook invocations and must be harmless.
run_hook --start '{not-json' || fail "malformed payload returned nonzero"
printf '' | run_hook --end || fail "empty payload returned nonzero"
run_hook --end '{}' || fail "end without start returned nonzero"

python3 - "$LOG" <<'PY' || exit 1
import json
import pathlib
import sys

lines = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
missing = lines[4]
if missing["event"] != "turn_start" or missing["prompt_sha256"] != "unavailable":
    raise SystemExit("FAIL: missing hash implementation did not degrade")
if "HASH_TOOL_SECRET" in pathlib.Path(sys.argv[1]).read_text():
    raise SystemExit("FAIL: degraded path leaked prompt content")
if lines[-1]["event"] != "turn_end" or lines[-1]["turn_id"] != "unknown":
    raise SystemExit("FAIL: end without start did not record unknown")
PY

# Overlapping turns on ONE surface. Claude can queue input, so a second
# UserPromptSubmit may arrive before the first Stop. With a single-slot state
# file the second start overwrote the first, leaving one start with no end and
# one end attributed to nothing - and an unmatched start reads identically to
# "the leader never reported a route", inflating the exact gap this instrument
# measures. The state file is a stack, so both turns must stay matched.
OVERLAP_HOME="$TEST_TMP/overlap-home"
overlap_hook() {
    env HOME="$OVERLAP_HOME" TERMMESH_TEAM=term-mesh \
        TERMMESH_SURFACE_ID=overlap-surface \
        TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token \
        "$HOOK" "$@"
}
overlap_hook --start '{"prompt":"outer turn"}' || fail "overlap start A returned nonzero"
overlap_hook --start '{"prompt":"inner turn"}' || fail "overlap start B returned nonzero"
# Simulate `leader turn route` for the inner turn. The production CLI creates
# this owner-only marker after atomically appending the stated route record.
inner_turn=$(tail -n 1 "$OVERLAP_HOME/.term-mesh/logs/.turn-current-overlap-surface")
printf 'stated\n' > "$OVERLAP_HOME/.term-mesh/logs/.turn-route-$inner_turn"
overlap_hook --end '{}' || fail "overlap end 1 returned nonzero"
overlap_hook --end '{}' || fail "overlap end 2 returned nonzero"

python3 - "$OVERLAP_HOME/.term-mesh/logs/turns.log" <<'PY' || exit 1
import json
import pathlib
import sys

lines = [json.loads(l) for l in pathlib.Path(sys.argv[1]).read_text().splitlines()]
starts = [l["turn_id"] for l in lines if l["event"] == "turn_start"]
ends = [l["turn_id"] for l in lines if l["event"] == "turn_end"]
if len(starts) != 2 or len(ends) != 2:
    raise SystemExit(f"FAIL: expected 2 starts and 2 ends, got {len(starts)}/{len(ends)}")
if "unknown" in ends:
    raise SystemExit("FAIL: an overlapping turn_end was orphaned")
if sorted(starts) != sorted(ends):
    raise SystemExit(f"FAIL: starts {starts} did not all match ends {ends}")
if ends[0] != starts[1] or ends[1] != starts[0]:
    raise SystemExit(f"FAIL: ends {ends} are not the LIFO pairing of starts {starts}")
end_records = [l for l in lines if l["event"] == "turn_end"]
if end_records[0].get("route_status") != "stated":
    raise SystemExit("FAIL: stated route marker was not consumed by Stop")
if end_records[1].get("route_status") != "unstated":
    raise SystemExit("FAIL: unstated overlap turn was not recorded")
marker = pathlib.Path(sys.argv[1]).with_name(f".turn-route-{ends[0]}")
if marker.exists():
    raise SystemExit("FAIL: consumed route marker was retained")
PY

# An argv-delivered payload must not sit in this process's argv: any same-user
# process can read a prompt out of `ps`. The hook copies it and clears argv.
grep -q 'set --' "$HOOK" || fail "argv is not cleared after the payload is copied"

printf '%s\n' 'PASS: leader turn hook logs private, correlated start/end boundaries'
