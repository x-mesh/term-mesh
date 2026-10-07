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
seen_turn_ids = []
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
    seen_turn_ids.append(start["turn_id"])
    if len(start["turn_id"]) != 16:
        raise SystemExit("FAIL: turn ID is not 16 hex characters")
    prompt = sys.argv[2 + offset // 2]
    expected_prompt_sha = hashlib.sha256(prompt.encode()).hexdigest()
    # The id carries a clock and a pid now, so it cannot be recomputed here.
    # What it must still be: lowercase hex of the stated width, correlated
    # start-to-end, and never shared by two turns.
    if start["turn_id"].strip("0123456789abcdef"):
        raise SystemExit("FAIL: turn ID is not lowercase hex")
    if start["prompt_bytes"] != len(prompt.encode()):
        raise SystemExit("FAIL: wrong prompt byte count")
    if start["prompt_sha256"] != expected_prompt_sha:
        raise SystemExit("FAIL: wrong prompt SHA-256")
if len(set(seen_turn_ids)) != len(seen_turn_ids):
    raise SystemExit(f"FAIL: two turns share one id: {seen_turn_ids}")
PY

# The same prompt twice in one session is ordinary — a repeated "continue" —
# and it used to hash to one id, which tm-agent counts as a damaged log line
# (`leader_participation_health`) rather than as two turns. Measured on a real
# host: an intact turns.log reported "malformed log line 1" and held the
# promotion gate shut.
REPEAT_HOME="$TEST_TMP/repeat"
mkdir -p "$REPEAT_HOME" || exit 1
repeat_hook() {
    HOME="$REPEAT_HOME" \
        TERMMESH_TEAM=turn-test \
        TERMMESH_SURFACE_ID=66666666-7777-8888-9999-000000000000 \
        TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token \
        "$HOOK" "$@"
}
for _ in 1 2; do
    repeat_hook --start '{"session_id":"repeat-session","prompt":"continue"}' \
        || fail "repeat start returned nonzero"
    repeat_hook --end '{"hook_event_name":"Stop","session_id":"repeat-session","stop_hook_active":false}' \
        || fail "repeat end returned nonzero"
done
python3 - "$REPEAT_HOME/.term-mesh/logs/turns.log" <<'REPEATPY' || exit 1
import json
import pathlib
import sys

records = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
starts = [r for r in records if r["event"] == "turn_start"]
if len(starts) != 2:
    raise SystemExit("FAIL: expected two starts, got %d" % len(starts))
if starts[0]["prompt_sha256"] != starts[1]["prompt_sha256"]:
    raise SystemExit("FAIL: the two repetitions were not the same prompt")
if starts[0]["turn_id"] == starts[1]["turn_id"]:
    raise SystemExit("FAIL: one prompt sent twice produced one turn id")
ends = [r for r in records if r["event"] == "turn_end"]
if sorted(r["turn_id"] for r in ends) != sorted(r["turn_id"] for r in starts):
    raise SystemExit("FAIL: ends did not close the two distinct starts")
REPEATPY

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
# Simulate `leader turn route` for the running outer turn. The production CLI creates
# this owner-only marker after atomically appending the stated route record.
outer_turn=$(head -n 1 "$OVERLAP_HOME/.term-mesh/logs/.turn-current-overlap-surface")
printf 'stated\n' > "$OVERLAP_HOME/.term-mesh/logs/.turn-route-$outer_turn"
overlap_hook --end '{}' || fail "overlap end 1 returned nonzero"

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
end_records = [l for l in lines if l["event"] == "turn_end"]
by_status = {record.get("route_status"): record["turn_id"] for record in end_records}
if by_status.get("stated") != starts[0]:
    raise SystemExit("FAIL: stated route marker was not consumed by Stop")
if by_status.get("absorbed") != starts[1]:
    raise SystemExit("FAIL: absorbed overlap prompt was not recorded")
marker = pathlib.Path(sys.argv[1]).with_name(f".turn-route-{starts[0]}")
if marker.exists():
    raise SystemExit("FAIL: consumed route marker was retained")
PY

# A mid-turn prompt absorbed into the running turn: TWO UserPromptSubmit events
# and ONE Stop. Plain LIFO closed the absorbed prompt and stranded the turn that
# had stated a route, leaving it start+route with no end — a shape `health()`
# counts in no outcome cohort and can never link, while the prompt that stated
# nothing was recorded `unstated`. Stop must close the route-marked turn.
ABSORB_HOME="$TEST_TMP/absorb-home"
absorb_hook() {
    env HOME="$ABSORB_HOME" TERMMESH_TEAM=term-mesh \
        TERMMESH_SURFACE_ID=absorb-surface \
        TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token \
        "$HOOK" "$@"
}
absorb_hook --start '{"prompt":"routed turn"}' || fail "absorb start A returned nonzero"
ABSORB_LOGS="$ABSORB_HOME/.term-mesh/logs"
routed_turn=$(tail -n 1 "$ABSORB_LOGS/.turn-current-absorb-surface")
printf 'stated\n' > "$ABSORB_LOGS/.turn-route-$routed_turn"
# The mid-turn message arrives before any Stop and never gets its own Stop.
absorb_hook --start '{"prompt":"mid-turn message"}' || fail "absorb start B returned nonzero"
absorb_hook --end '{}' || fail "absorb end returned nonzero"

python3 - "$ABSORB_LOGS/turns.log" "$routed_turn" <<'PY' || exit 1
import json
import pathlib
import sys

records = [json.loads(l) for l in pathlib.Path(sys.argv[1]).read_text().splitlines()]
routed = sys.argv[2]
ends = [r for r in records if r["event"] == "turn_end"]
routed_ends = [r for r in ends if r.get("route_status") != "absorbed"]
if len(routed_ends) != 1:
    raise SystemExit(f"FAIL: expected exactly one routed turn_end, got {routed_ends}")
if routed_ends[0]["turn_id"] != routed:
    raise SystemExit(
        f"FAIL: Stop closed {routed_ends[0]['turn_id']}, stranding routed turn {routed}"
    )
if routed_ends[0].get("route_status") != "stated":
    raise SystemExit("FAIL: the routed turn's end was not recorded stated")
marker = pathlib.Path(sys.argv[1]).with_name(f".turn-route-{routed}")
if marker.exists():
    raise SystemExit("FAIL: consumed route marker was retained")
# The absorbed prompt has no Stop of its own. It must be removed from the stack
# and receive an explicit terminal record so health can exclude it.
stack = pathlib.Path(sys.argv[1]).with_name(".turn-current-absorb-surface")
remaining = [l for l in stack.read_text().splitlines() if l.strip()] if stack.exists() else []
starts = [r["turn_id"] for r in records if r["event"] == "turn_start"]
absorbed = [t for t in starts if t != routed]
if remaining:
    raise SystemExit(f"FAIL: absorbed prompts remained on stack: {remaining}")
absorbed_ends = [
    r["turn_id"] for r in records
    if r["event"] == "turn_end" and r.get("route_status") == "absorbed"
]
if absorbed_ends != absorbed:
    raise SystemExit(f"FAIL: absorbed ends {absorbed_ends}, expected {absorbed}")
PY

# If route classification happens after the absorbed prompt was pushed, the
# running turn is still the oldest open entry. Pin that opposite ordering.
LATE_HOME="$TEST_TMP/late-route-home"
late_hook() {
    env HOME="$LATE_HOME" TERMMESH_TEAM=term-mesh \
        TERMMESH_SURFACE_ID=late-route-surface \
        TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token \
        "$HOOK" "$@"
}
late_hook --start '{"prompt":"running before route"}' || fail "late start A returned nonzero"
LATE_LOGS="$LATE_HOME/.term-mesh/logs"
late_running=$(head -n 1 "$LATE_LOGS/.turn-current-late-route-surface")
late_hook --start '{"prompt":"absorbed before route"}' || fail "late start B returned nonzero"
printf 'stated\n' > "$LATE_LOGS/.turn-route-$late_running"
late_hook --end '{}' || fail "late end returned nonzero"
python3 - "$LATE_LOGS/turns.log" "$late_running" <<'PY' || exit 1
import json
import pathlib
import sys

records = [json.loads(l) for l in pathlib.Path(sys.argv[1]).read_text().splitlines()]
routed = [
    r for r in records
    if r["event"] == "turn_end" and r.get("route_status") == "stated"
]
if len(routed) != 1 or routed[0]["turn_id"] != sys.argv[2]:
    raise SystemExit(f"FAIL: late route closed the wrong entry: {routed}")
absorbed = [
    r for r in records
    if r["event"] == "turn_end" and r.get("route_status") == "absorbed"
]
if len(absorbed) != 1:
    raise SystemExit(f"FAIL: late route did not classify absorbed prompt: {absorbed}")
PY

# An argv-delivered payload must not sit in this process's argv: any same-user
# process can read a prompt out of `ps`. The hook copies it and clears argv.
grep -q 'set --' "$HOOK" || fail "argv is not cleared after the payload is copied"

# --- delegation floor -------------------------------------------------------
# UserPromptSubmit stdout reaches the leader's context, so --start is the one
# place the hook speaks rather than observes. Every unusable input must leave
# stdout empty: a hook that garbles a turn costs more than one that says
# nothing.
FLOOR_HOME="$TEST_TMP/floor"
FLOOR_CTL="$TEST_TMP/control"
mkdir -p "$FLOOR_HOME" "$FLOOR_CTL" || exit 1
FLOOR_LOG="$FLOOR_HOME/.term-mesh/logs/turns.log"

floor_hook() {
    _ctl="$1"
    shift
    HOME="$FLOOR_HOME" \
        TERMMESH_TEAM=floor-test \
        TERMMESH_SURFACE_ID=99999999-8888-7777-6666-555555555555 \
        TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token \
        TERMMESH_LEADER_TEAM_UUID=05AC84AA-1E7C-4B21-86CE-77239B138078 \
        TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE="$_ctl" \
        "$HOOK" "$@"
}

cat > "$FLOOR_CTL/delegated.json" <<'JSON' || exit 1
{"schema_version":1,"delegation_effective":"delegated","available_workers":3,
 "worker_names":["executor","architect","reviewer"],"kill_switch":false,
 "project_id":"floor-test"}
JSON
cat > "$FLOOR_CTL/leader-first-solo.json" <<'JSON' || exit 1
{"schema_version":1,"delegation_effective":"leaderFirst","available_workers":1,
 "worker_names":["executor"],"kill_switch":false,"project_id":"floor-test"}
JSON
cat > "$FLOOR_CTL/killed.json" <<'JSON' || exit 1
{"schema_version":1,"delegation_effective":"delegated","available_workers":3,"kill_switch":true,
 "project_id":"floor-test"}
JSON
# Legacy rollout fields stay diagnostic. They do not suppress delegated guidance.
cat > "$FLOOR_CTL/mode-off.json" <<'JSON' || exit 1
{"schema_version":1,"delegation_effective":"delegated","available_workers":3,
 "worker_names":["executor","architect","reviewer"],"kill_switch":false,
 "mode":"off","project_id":"floor-test"}
JSON
cat > "$FLOOR_CTL/mode-shadow.json" <<'JSON' || exit 1
{"schema_version":1,"delegation_effective":"delegated","available_workers":3,
 "worker_names":["executor","architect","reviewer"],"kill_switch":false,
 "mode":"shadow","project_id":"floor-test"}
JSON
printf 'not json {{{' > "$FLOOR_CTL/broken.json" || exit 1

FLOOR_OUT=$(floor_hook "$FLOOR_CTL/delegated.json" --start '{"prompt":"first","session_id":"floor-1"}') \
    || fail "delegated start returned nonzero"
case "$FLOOR_OUT" in
    *"level: delegated"*) ;;
    *) fail "delegated floor was not injected: $FLOOR_OUT" ;;
esac
case "$FLOOR_OUT" in
    *executor*) ;;
    *) fail "roster missing from injected floor: $FLOOR_OUT" ;;
esac
case "$FLOOR_OUT" in
    *"Fill every useful independent unit"*) ;;
    *) fail "delegated max-capacity rule missing: $FLOOR_OUT" ;;
esac

# A continued Stop must stay silent and avoid a continuation loop.
FLOOR_OUT=$(floor_hook "$FLOOR_CTL/delegated.json" --end '{"session_id":"floor-1","stop_hook_active":true}') \
    || fail "delegated end returned nonzero"
[ -z "$FLOOR_OUT" ] || fail "continued --end wrote to stdout: $FLOOR_OUT"

for quiet in leader-first-solo broken missing; do
    FLOOR_OUT=$(floor_hook "$FLOOR_CTL/$quiet.json" --start "{\"prompt\":\"$quiet\"}") \
        || fail "$quiet start returned nonzero"
    [ -z "$FLOOR_OUT" ] || fail "$quiet should inject nothing, got: $FLOOR_OUT"
done
FLOOR_OUT=$(floor_hook "$FLOOR_CTL/mode-shadow.json" --start '{"prompt":"shadow","session_id":"floor-s"}') \
    || fail "shadow start returned nonzero"
case "$FLOOR_OUT" in
    *"level: delegated"*) ;;
    *) fail "record-only must still inject the floor: $FLOOR_OUT" ;;
esac
for legacy in killed mode-off; do
    FLOOR_OUT=$(floor_hook "$FLOOR_CTL/$legacy.json" --start "{\"prompt\":\"$legacy\"}") \
        || fail "$legacy start returned nonzero"
    case "$FLOOR_OUT" in
        *"level: delegated"*) ;;
        *) fail "$legacy must not suppress delegated guidance: $FLOOR_OUT" ;;
    esac
done

FLOOR_OUT=$(env -u TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE HOME="$FLOOR_HOME" \
    TERMMESH_TEAM=floor-test TERMMESH_SURFACE_ID=99999999-8888-7777-6666-555555555555 \
    TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token "$HOOK" --start '{"prompt":"no control"}') \
    || fail "unset control file returned nonzero"
[ -z "$FLOOR_OUT" ] || fail "unset control file should inject nothing, got: $FLOOR_OUT"

# task_dispatch is written by the app, never claimed by the leader, so whether
# a delegated turn met its floor is the one participation signal that does not
# depend on the leader reporting anything.
floor_hook "$FLOOR_CTL/delegated.json" --start '{"prompt":"unmet turn","session_id":"floor-2"}' >/dev/null \
    || fail "unmet start returned nonzero"
FLOOR_OUT=$(floor_hook "$FLOOR_CTL/delegated.json" --end '{"session_id":"floor-2","stop_hook_active":false}') \
    || fail "unmet end returned nonzero"
python3 - "$FLOOR_OUT" <<'BLOCKPY' || exit 1
import json
import sys

value = json.loads(sys.argv[1])
if value.get("decision") != "block" or "eligible worker dispatch" not in value.get("reason", ""):
    raise SystemExit("FAIL: unmet delegation did not block Stop: %r" % value)
BLOCKPY

floor_hook "$FLOOR_CTL/delegated.json" --start '{"prompt":"continued turn","session_id":"floor-continued"}' >/dev/null \
    || fail "continued start returned nonzero"
FLOOR_OUT=$(floor_hook "$FLOOR_CTL/delegated.json" --end '{"session_id":"floor-continued","stop_hook_active":true}') \
    || fail "continued end returned nonzero"
[ -z "$FLOOR_OUT" ] || fail "active Stop hook blocked recursively: $FLOOR_OUT"

floor_hook "$FLOOR_CTL/delegated.json" --start '{"prompt":"met turn","session_id":"floor-3"}' >/dev/null \
    || fail "met start returned nonzero"
printf '%s\n' '{"event":"task_dispatch","turn_id":"req-1","ts":"2026-01-01T00:00:00Z","team":"floor-test","task_id":"t1","worker":"executor","delivery":"created"}' \
    >> "$FLOOR_LOG" || exit 1
floor_hook "$FLOOR_CTL/delegated.json" --end '{"session_id":"floor-3"}' >/dev/null \
    || fail "met end returned nonzero"

# leaderFirst states no floor a turn can miss, so the field must be absent.
floor_hook "$FLOOR_CTL/leader-first-solo.json" --start '{"prompt":"lf turn","session_id":"floor-4"}' >/dev/null \
    || fail "leader-first start returned nonzero"
floor_hook "$FLOOR_CTL/leader-first-solo.json" --end '{"session_id":"floor-4"}' >/dev/null \
    || fail "leader-first end returned nonzero"

python3 - "$FLOOR_LOG" <<'PY' || exit 1
import json
import pathlib
import sys

records = []
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if line:
        records.append(json.loads(line))

ends = [r for r in records if r["event"] == "turn_end"]
# The last four ends are, in order: delegated with no dispatch, its continuation,
# delegated with one dispatch, then leaderFirst. Checking them positionally keeps this honest
# about ordering instead of counting occurrences that earlier cases also add.
expected = ["unmet", "unmet", "met", None]
actual = [r.get("delegation_floor") for r in ends[-4:]]
if actual != expected:
    raise SystemExit(f"FAIL: delegation floors were {actual}, expected {expected}")
PY

# Legacy mode does not stop the mandatory floor record.
floor_hook "$FLOOR_CTL/mode-off.json" --start '{"prompt":"off turn","session_id":"floor-off"}' >/dev/null \
    || fail "mode-off start returned nonzero"
floor_hook "$FLOOR_CTL/mode-off.json" --end '{"session_id":"floor-off"}' >/dev/null \
    || fail "mode-off end returned nonzero"

python3 - "$FLOOR_LOG" <<'OFFPY' || exit 1
import json
import pathlib
import sys

records = []
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if line:
        records.append(json.loads(line))

ends = [r for r in records if r["event"] == "turn_end"]
if not ends:
    raise SystemExit("FAIL: no turn_end records")
last = ends[-1]
if last.get("delegation_floor") != "unmet":
    raise SystemExit("FAIL: legacy mode suppressed the floor: %s" % last.get("delegation_floor"))
OFFPY

# A bare stated route is not a reason: it must still continue the turn once,
# or any route would skip the floor. `--route direct --no-dispatch-reason`
# adds a `no_dispatch` line to the marker, and only that ends the turn.
routed_floor_turn_id() {
    head -n 1 "$FLOOR_HOME/.term-mesh/logs/.turn-current-99999999-8888-7777-6666-555555555555"
}
floor_hook "$FLOOR_CTL/delegated.json" --start '{"prompt":"bare route turn","session_id":"floor-bare"}' >/dev/null \
    || fail "bare-route start returned nonzero"
bare_turn=$(routed_floor_turn_id)
[ -n "$bare_turn" ] || fail "bare-route turn id missing"
printf 'stated\n' > "$FLOOR_HOME/.term-mesh/logs/.turn-route-$bare_turn" || exit 1
FLOOR_OUT=$(floor_hook "$FLOOR_CTL/delegated.json" --end '{"session_id":"floor-bare","stop_hook_active":false}') \
    || fail "bare-route end returned nonzero"
case "$FLOOR_OUT" in
    *'"decision":"block"'*"--no-dispatch-reason"*) ;;
    *) fail "a bare stated route skipped the delegation floor: $FLOOR_OUT" ;;
esac

floor_hook "$FLOOR_CTL/delegated.json" --start '{"prompt":"reasoned direct turn","session_id":"floor-routed"}' >/dev/null \
    || fail "routed start returned nonzero"
routed_floor_turn=$(routed_floor_turn_id)
[ -n "$routed_floor_turn" ] || fail "routed turn id missing"
printf 'stated\nno_dispatch\n' > "$FLOOR_HOME/.term-mesh/logs/.turn-route-$routed_floor_turn" || exit 1
FLOOR_OUT=$(floor_hook "$FLOOR_CTL/delegated.json" --end '{"session_id":"floor-routed","stop_hook_active":false}') \
    || fail "routed end returned nonzero"
[ -z "$FLOOR_OUT" ] || fail "a direct route with a no-dispatch reason was still blocked: $FLOOR_OUT"
python3 - "$FLOOR_LOG" "$routed_floor_turn" <<'ROUTEDPY' || exit 1
import json
import pathlib
import sys

records = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
ends = [r for r in records if r["event"] == "turn_end" and r["turn_id"] == sys.argv[2]]
if len(ends) != 1:
    raise SystemExit("FAIL: routed turn has %d turn_end records" % len(ends))
if ends[0].get("route_status") != "stated" or ends[0].get("delegation_floor") != "unmet":
    raise SystemExit("FAIL: routed turn_end was %r" % ends[0])
ROUTEDPY

# The per-Project execution options, which only reach the hook through this
# file: a cap of one means waves are off rather than small. The legacy injection
# switch cannot silence mandatory guidance.
cat > "$FLOOR_CTL/capped.json" <<'JSON' || exit 1
{"schema_version":1,"delegation_effective":"delegated","available_workers":4,
 "worker_names":["a","b","c","d"],"kill_switch":false,"project_id":"floor-test",
 "max_parallel_workers":2}
JSON
cat > "$FLOOR_CTL/no-waves.json" <<'JSON' || exit 1
{"schema_version":1,"delegation_effective":"leaderFirst","available_workers":4,
 "worker_names":["a","b","c","d"],"kill_switch":false,"project_id":"floor-test",
 "max_parallel_workers":1}
JSON
cat > "$FLOOR_CTL/injection-off.json" <<'JSON' || exit 1
{"schema_version":1,"delegation_effective":"delegated","available_workers":3,"kill_switch":false,
 "project_id":"floor-test","inject_directive":false}
JSON
cat > "$FLOOR_CTL/ten-workers.json" <<'JSON' || exit 1
{"schema_version":1,"delegation_effective":"delegated","available_workers":12,
 "worker_names":["a","b","c","d","e","f","g","h","i","j","k","l"],
 "kill_switch":false,"project_id":"floor-test","max_parallel_workers":12}
JSON

FLOOR_OUT=$(floor_hook "$FLOOR_CTL/capped.json" --start '{"prompt":"capped"}') \
    || fail "capped start returned nonzero"
case "$FLOOR_OUT" in
    *"up to 2 workers"*) ;;
    *) fail "cap not reflected in the floor: $FLOOR_OUT" ;;
esac
case "$FLOOR_OUT" in
    *"max parallel: 2"*) ;;
    *) fail "cap missing from the header: $FLOOR_OUT" ;;
esac
case "$FLOOR_OUT" in
    *"TERMMESH_LEADER_ROUTE_FILE="*) ;;
    *) fail "current Project route missing from the floor: $FLOOR_OUT" ;;
esac

FLOOR_OUT=$(floor_hook "$FLOOR_CTL/ten-workers.json" --start '{"prompt":"ten workers"}') \
    || fail "ten-worker start returned nonzero"
case "$FLOOR_OUT" in
    *"max parallel: 10"*) ;;
    *) fail "ten-worker header cap not enforced: $FLOOR_OUT" ;;
esac
case "$FLOOR_OUT" in
    *"up to 10 workers"*) ;;
    *) fail "ten-worker floor cap not enforced: $FLOOR_OUT" ;;
esac

# leaderFirst with waves capped off has nothing left to say beyond the default.
FLOOR_OUT=$(floor_hook "$FLOOR_CTL/no-waves.json" --start '{"prompt":"no waves"}') \
    || fail "no-waves start returned nonzero"
[ -z "$FLOOR_OUT" ] || fail "leaderFirst with cap 1 should stay silent, got: $FLOOR_OUT"

FLOOR_OUT=$(floor_hook "$FLOOR_CTL/injection-off.json" --start '{"prompt":"off","session_id":"floor-5"}') \
    || fail "injection-off start returned nonzero"
case "$FLOOR_OUT" in
    *"level: delegated"*) ;;
    *) fail "inject_directive=false suppressed mandatory guidance: $FLOOR_OUT" ;;
esac

# ...but turning injection off must not turn measurement off with it.
floor_hook "$FLOOR_CTL/injection-off.json" --end '{"session_id":"floor-5"}' >/dev/null \
    || fail "injection-off end returned nonzero"
python3 - "$FLOOR_LOG" <<'PY' || exit 1
import json
import pathlib
import sys

records = [
    json.loads(line)
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
last_end = [r for r in records if r["event"] == "turn_end"][-1]
if last_end.get("delegation_floor") != "unmet":
    raise SystemExit(
        "FAIL: injection off still has to measure the floor, got "
        + repr(last_end.get("delegation_floor"))
    )
PY

# A control file belonging to another Project must not inject this Project's
# floor, even with an otherwise valid, well-formed payload.
cat > "$FLOOR_CTL/foreign-project.json" <<'JSON' || exit 1
{"schema_version":1,"delegation_effective":"delegated","available_workers":3,
 "worker_names":["executor"],"kill_switch":false,"project_id":"other-project",
 "session_id":"foreign-session"}
JSON
FLOOR_OUT=$(floor_hook "$FLOOR_CTL/foreign-project.json" --start '{"prompt":"foreign"}') \
    || fail "foreign-project start returned nonzero"
[ -z "$FLOOR_OUT" ] || fail "mismatched project_id should inject nothing, got: $FLOOR_OUT"

# An unrecognized schema_version must not be trusted, even with a matching
# project_id and an otherwise well-formed payload.
cat > "$FLOOR_CTL/bad-schema.json" <<'JSON' || exit 1
{"schema_version":2,"delegation_effective":"delegated","available_workers":3,
 "worker_names":["executor"],"kill_switch":false,"project_id":"floor-test"}
JSON
FLOOR_OUT=$(floor_hook "$FLOOR_CTL/bad-schema.json" --start '{"prompt":"bad-schema"}') \
    || fail "bad-schema start returned nonzero"
[ -z "$FLOOR_OUT" ] || fail "unrecognized schema_version should inject nothing, got: $FLOOR_OUT"

# An empty TERMMESH_TEAM cannot prove that the control file belongs to this Project.
FLOOR_OUT=$(HOME="$FLOOR_HOME" \
    TERMMESH_TEAM= \
    TERMMESH_SURFACE_ID=99999999-8888-7777-6666-555555555555 \
    TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token \
    TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE="$FLOOR_CTL/delegated.json" \
    "$HOOK" --start '{"prompt":"no team name"}') \
    || fail "empty TERMMESH_TEAM start returned nonzero"
[ -z "$FLOOR_OUT" ] || fail "an empty TERMMESH_TEAM must fail closed, got: $FLOOR_OUT"

# Project identity also gates control-file session adoption and the end-side
# delegation verdict. A foreign or unidentified Project must affect neither.
for identity_case in foreign empty; do
    if [ "$identity_case" = foreign ]; then
        identity_team=floor-test
        identity_control="$FLOOR_CTL/foreign-project.json"
    else
        identity_team=
        identity_control="$FLOOR_CTL/delegated.json"
    fi
    env -u TERMMESH_LEADER_SESSION_ID HOME="$FLOOR_HOME" \
        TERMMESH_TEAM="$identity_team" \
        TERMMESH_SURFACE_ID=identity-$identity_case \
        TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token \
        TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE="$identity_control" \
        "$HOOK" --start "{\"prompt\":\"identity $identity_case\",\"session_id\":\"payload-$identity_case\"}" >/dev/null \
        || fail "$identity_case identity start returned nonzero"
    env -u TERMMESH_LEADER_SESSION_ID HOME="$FLOOR_HOME" \
        TERMMESH_TEAM="$identity_team" \
        TERMMESH_SURFACE_ID=identity-$identity_case \
        TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token \
        TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE="$identity_control" \
        "$HOOK" --end "{\"session_id\":\"payload-$identity_case\"}" >/dev/null \
        || fail "$identity_case identity end returned nonzero"
done

python3 - "$FLOOR_LOG" <<'IDENTITYPY' || exit 1
import json
import pathlib
import sys

records = [
    json.loads(line)
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
starts = [record for record in records if record.get("event") == "turn_start"][-2:]
ends = [record for record in records if record.get("event") == "turn_end"][-2:]
if len(starts) != 2 or any("leader_session_id" in record for record in starts):
    raise SystemExit("FAIL: unidentified Project adopted a control session: %r" % starts)
if len(ends) != 2 or any("delegation_floor" in record for record in ends):
    raise SystemExit("FAIL: unidentified Project recorded a delegation floor: %r" % ends)
IDENTITYPY

# A remote leader pane also carries TERMMESH_LEADER_PROJECT_ID, a display ID
# ("team:<uuid>") distinct from the team name control payloads use as
# project_id. It must not be compared against project_id: doing so silently
# kills the floor and session_id adoption for every remote leader.
FLOOR_OUT=$(HOME="$FLOOR_HOME" \
    TERMMESH_TEAM=floor-test \
    TERMMESH_SURFACE_ID=99999999-8888-7777-6666-555555555555 \
    TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token \
    TERMMESH_LEADER_TEAM_UUID=05AC84AA-1E7C-4B21-86CE-77239B138078 \
    TERMMESH_LEADER_PROJECT_ID=team:some-uuid \
    TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE="$FLOOR_CTL/delegated.json" \
    "$HOOK" --start '{"prompt":"remote leader"}') \
    || fail "remote leader start returned nonzero"
case "$FLOOR_OUT" in
    *"level: delegated"*) ;;
    *) fail "remote leader's floor was suppressed by TERMMESH_LEADER_PROJECT_ID: $FLOOR_OUT" ;;
esac

printf '%s\n' 'PASS: leader turn hook logs private, correlated start/end boundaries'
printf '%s\n' 'PASS: leader turn hook injects and measures the delegation floor'
# Another team's dispatches are not this team's delegation.
#
# The first version of this verdict walked the log back to this turn's own
# turn_start and counted every task_dispatch on the way. Two things broke it:
# the id a leader states with `leader turn route` is not always the one the
# hook recorded, so the walk could run past every recent record and match a
# start from hours earlier — and it counted dispatches from every team on the
# host. A live run reported "met" for a turn that dispatched nothing, on the
# strength of another project's records from six hours before.
STRAY_HOME="$TEST_TMP/stray"
STRAY_CTL="$TEST_TMP/stray-ctl"
mkdir -p "$STRAY_HOME/.term-mesh/logs" "$STRAY_CTL" || exit 1
STRAY_LOG="$STRAY_HOME/.term-mesh/logs/turns.log"

cat > "$STRAY_CTL/delegated.json" <<'JSON' || exit 1
{"delegation_effective":"delegated","available_workers":2,
 "worker_names":["a","b"],"kill_switch":false,"project_id":"mine"}
JSON

stray_hook() {
    HOME="$STRAY_HOME" \
        TERMMESH_TEAM=mine \
        TERMMESH_SURFACE_ID=stray-surface \
        TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token \
        TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE="$STRAY_CTL/delegated.json" \
        "$HOOK" "$@"
}

# An old dispatch belonging to this team, before the turn begins: it is part of
# the baseline, so it must not make the new turn look delegated.
printf '%s\n' '{"event":"task_dispatch","turn_id":"old","ts":"2026-01-01T00:00:00Z","team":"mine","task_id":"t0","worker":"a","delivery":"created"}' \
    >> "$STRAY_LOG" || exit 1

stray_hook --start '{"prompt":"turn one","session_id":"stray-1"}' >/dev/null \
    || fail "stray start returned nonzero"

# ...and a different team dispatching while this turn runs.
printf '%s\n' '{"event":"task_dispatch","turn_id":"other","ts":"2026-01-01T00:00:01Z","team":"someone-else","task_id":"t1","worker":"x","delivery":"created"}' \
    >> "$STRAY_LOG" || exit 1

stray_hook --end '{"session_id":"stray-1"}' >/dev/null \
    || fail "stray end returned nonzero"

python3 - "$STRAY_LOG" <<'PY' || exit 1
import json
import pathlib
import sys

records = [
    json.loads(line)
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
last_end = [r for r in records if r["event"] == "turn_end"][-1]
if last_end.get("delegation_floor") != "unmet":
    raise SystemExit(
        "FAIL: a prior dispatch and another team's dispatch must not read as met, got "
        + repr(last_end.get("delegation_floor"))
    )
PY

# With no baseline — a Stop that never saw a Start — the verdict is withheld
# rather than guessed.
rm -f "$STRAY_HOME/.term-mesh/logs/.turn-dispatch-stray-surface" 2>/dev/null || true
stray_hook --end '{"session_id":"stray-2"}' >/dev/null \
    || fail "baseline-less end returned nonzero"
python3 - "$STRAY_LOG" <<'PY' || exit 1
import json
import pathlib
import sys

records = [
    json.loads(line)
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
last_end = [r for r in records if r["event"] == "turn_end"][-1]
if "delegation_floor" in last_end:
    raise SystemExit(
        "FAIL: without a baseline the floor must be withheld, got "
        + repr(last_end.get("delegation_floor"))
    )
PY

# A long turn on a busy log must still read as delegated.
#
# The verdict used to count a fixed tail of the log at both ends and compare
# the two numbers. Once the log outgrew that tail during a turn, the old
# dispatches that slid out of it cancelled the ones the turn added, and a turn
# that delegated three tasks reported exactly the same number as it started
# with — "unmet". The baseline is a byte offset now, so nothing that scrolls
# out of view can cancel a real dispatch.
WINDOW_HOME="$TEST_TMP/window"
WINDOW_CTL="$TEST_TMP/window-ctl"
mkdir -p "$WINDOW_HOME/.term-mesh/logs" "$WINDOW_CTL" || exit 1
WINDOW_LOG="$WINDOW_HOME/.term-mesh/logs/turns.log"

cat > "$WINDOW_CTL/delegated.json" <<'JSON' || exit 1
{"delegation_effective":"delegated","available_workers":2,
 "worker_names":["a","b"],"kill_switch":false,"project_id":"mine"}
JSON

window_hook() {
    HOME="$WINDOW_HOME" \
        TERMMESH_TEAM=mine \
        TERMMESH_SURFACE_ID=window-surface \
        TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token \
        TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE="$WINDOW_CTL/delegated.json" \
        "$HOOK" "$@"
}

# Same shape as the live failure: three of this team's dispatches already in
# the log, then enough traffic that they fall out of any fixed tail.
window_fill() {
    python3 - "$WINDOW_LOG" "$1" "$2" <<'PY' || exit 1
import sys

log_path, dispatches, filler = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(log_path, "a", encoding="utf-8") as handle:
    for index in range(dispatches):
        handle.write(
            '{"event":"task_dispatch","turn_id":"w%d","ts":"2026-01-01T00:00:00Z",'
            '"team":"mine","task_id":"w%d","worker":"a","delivery":"created"}\n'
            % (index, index)
        )
    for index in range(filler):
        handle.write(
            '{"event":"task_lifecycle","turn_id":"f%d","ts":"2026-01-01T00:00:00Z",'
            '"team":"noise","task_status":"running"}\n' % index
        )
PY
}

window_fill 3 7000
window_hook --start '{"prompt":"long turn","session_id":"window-1"}' >/dev/null \
    || fail "window start returned nonzero"
window_fill 3 7000
window_hook --end '{"session_id":"window-1"}' >/dev/null \
    || fail "window end returned nonzero"

python3 - "$WINDOW_LOG" <<'PY' || exit 1
import json
import pathlib
import sys

records = [
    json.loads(line)
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
last_end = [r for r in records if r["event"] == "turn_end"][-1]
if last_end.get("delegation_floor") != "met":
    raise SystemExit(
        "FAIL: dispatches during a long turn must read as met, got "
        + repr(last_end.get("delegation_floor"))
    )
PY

# An asynchronous leader is re-invoked to collect work it dispatched in an
# earlier turn. That turn dispatches nothing, and it was blocked as if the
# leader had done the work itself. Work this leader session already has out —
# still in flight, or finished since the previous turn — satisfies the floor
# under its own name; work that is stale or another session's does not.
ASYNC_HOME="$TEST_TMP/async"
ASYNC_CTL="$TEST_TMP/async-ctl"
mkdir -p "$ASYNC_HOME/.term-mesh/logs" "$ASYNC_CTL" || exit 1
ASYNC_LOG="$ASYNC_HOME/.term-mesh/logs/turns.log"

cat > "$ASYNC_CTL/delegated.json" <<'JSON' || exit 1
{"schema_version":1,"delegation_effective":"delegated","available_workers":2,
 "worker_names":["a","b"],"kill_switch":false,"project_id":"mine",
 "session_id":"async-leader"}
JSON

async_hook() {
    HOME="$ASYNC_HOME" \
        TERMMESH_TEAM=mine \
        TERMMESH_SURFACE_ID=async-surface \
        TERMMESH_LEADER_REQUEST_TOKEN=leader-only-token \
        TERMMESH_LEADER_SESSION_ID=async-leader \
        TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE="$ASYNC_CTL/delegated.json" \
        "$HOOK" "$@"
}

# async_task <event> <task_id> <status-or-empty> <age-seconds> <session>
async_task() {
    python3 - "$ASYNC_LOG" "$@" <<'PY' || exit 1
import json
import sys
from datetime import datetime, timedelta, timezone

log_path, event, task_id, status, age, session = sys.argv[1:7]
ts = (datetime.now(timezone.utc) - timedelta(seconds=int(age))).strftime("%Y-%m-%dT%H:%M:%SZ")
record = {"event": event, "turn_id": task_id, "ts": ts, "team": "mine",
          "task_id": task_id, "worker": "a", "leader_session_id": session}
if event == "task_dispatch":
    record["task_delivery"] = "created"
else:
    record["task_status"] = status
with open(log_path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY
}

# async_turn <name>: one prompt that dispatches nothing; prints Stop's stdout.
async_turn() {
    async_hook --start "{\"prompt\":\"$1\",\"session_id\":\"async-$1\"}" >/dev/null \
        || fail "async $1 start returned nonzero"
    async_hook --end "{\"session_id\":\"async-$1\",\"stop_hook_active\":false}" \
        || fail "async $1 end returned nonzero"
}

async_floor() {
    python3 - "$ASYNC_LOG" "$1" "$2" <<'PY' || exit 1
import json
import pathlib
import sys

log_path, expected, label = sys.argv[1:4]
records = [
    json.loads(line)
    for line in pathlib.Path(log_path).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
actual = [r for r in records if r["event"] == "turn_end"][-1].get("delegation_floor")
if actual != expected:
    raise SystemExit("FAIL: %s: expected %r, got %r" % (label, expected, actual))
PY
}

# Turn 1 dispatches two tasks, so it meets the floor the ordinary way.
async_hook --start '{"prompt":"dispatch","session_id":"async-dispatch"}' >/dev/null \
    || fail "async dispatch start returned nonzero"
async_task task_dispatch t1 "" 0 async-leader
async_task task_dispatch t2 "" 0 async-leader
async_hook --end '{"session_id":"async-dispatch"}' >/dev/null \
    || fail "async dispatch end returned nonzero"
async_floor met "dispatching turn"

# Turn 2: the user asks something while both workers run.
ASYNC_OUT=$(async_turn inflight)
async_floor met_by_inflight_or_collected "turn with prior work in flight"
[ -z "$ASYNC_OUT" ] || fail "in-flight turn was blocked: $ASYNC_OUT"

# Turn 3: a background wait returns and the leader collects the results.
async_task task_lifecycle t1 completed 0 async-leader
async_task task_lifecycle t2 review_ready 0 async-leader
ASYNC_OUT=$(async_turn collect)
async_floor met_by_inflight_or_collected "collection turn"
[ -z "$ASYNC_OUT" ] || fail "collection turn was blocked: $ASYNC_OUT"

# Turn 4: everything was collected last turn. Doing the work directly now is
# exactly what the floor exists to stop. A stale dispatch with no terminal
# record and another session's in-flight task change nothing.
async_task task_dispatch stale "" 10800 async-leader
async_task task_dispatch foreign "" 0 other-leader
ASYNC_OUT=$(async_turn direct)
async_floor unmet "turn with only collected, stale, or foreign work"
case "$ASYNC_OUT" in
    *'"decision":"block"'*) ;;
    *) fail "a direct turn with nothing outstanding was not blocked: $ASYNC_OUT" ;;
esac

# New hook records carry Project identity when the leader launch provides it.
IDENTITY_HOME="$TEST_TMP/identity"
mkdir -p "$IDENTITY_HOME/.term-mesh/logs" || exit 1
IDENTITY_CONTROL="$IDENTITY_HOME/control.json"
printf '%s\n' '{"schema_version":1,"project_id":"aic","session_id":"adopted-session"}' > "$IDENTITY_CONTROL" || exit 1
HOME="$IDENTITY_HOME" \
    TERMMESH_TEAM=aic \
    TERMMESH_SURFACE_ID=identity-surface \
    TERMMESH_LEADER_REQUEST_TOKEN=leader-token \
    TERMMESH_LEADER_TEAM_UUID=05AC84AA \
    TERMMESH_LEADER_SESSION_ID=leader-session \
    TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE="$IDENTITY_CONTROL" \
    "$HOOK" --start '{"prompt":"identity","session_id":"hook-session"}' >/dev/null \
    || fail "identity start returned nonzero"
HOME="$IDENTITY_HOME" \
    TERMMESH_TEAM=aic \
    TERMMESH_SURFACE_ID=identity-surface \
    TERMMESH_LEADER_REQUEST_TOKEN=leader-token \
    TERMMESH_LEADER_TEAM_UUID=05AC84AA \
    TERMMESH_LEADER_SESSION_ID=leader-session \
    TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE="$IDENTITY_CONTROL" \
    "$HOOK" --end '{"session_id":"hook-session"}' >/dev/null \
    || fail "identity end returned nonzero"
python3 - "$IDENTITY_HOME/.term-mesh/logs/turns.log" <<'PY' || exit 1
import json
import pathlib
import sys

records = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
if not records or any(record.get("team_uuid") != "05AC84AA" for record in records):
    raise SystemExit("FAIL: hook records did not preserve team_uuid")
if any(record.get("leader_session_id") != "adopted-session" for record in records):
    raise SystemExit("FAIL: hook records did not refresh leader_session_id")
PY

printf '%s\n' 'PASS: leader turn hook honours per-Project execution options'
printf '%s\n' 'PASS: delegation floor counts only this team, only this turn'
printf '%s\n' 'PASS: delegation floor survives a log that outgrows any fixed tail'
printf '%s\n' 'PASS: delegation floor lets an async leader collect work it already dispatched'
printf '%s\n' 'PASS: leader turn hook records scoped Project identity'
