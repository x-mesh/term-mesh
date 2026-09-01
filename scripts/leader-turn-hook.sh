#!/bin/sh
# Record leader turn boundaries without sending prompt content anywhere.
#
# This is the remote leader hook path. Local leader wiring can use the
# launch-scoped `--settings` injection in Resources/bin/claude; this script
# does not assume or require user-level hook installation.
#
# Usage: wire `--start` to Claude Code's UserPromptSubmit hook and `--end`
# to its Stop hook. Claude passes the UserPromptSubmit prompt as `.prompt`,
# but its Stop payload contains session/stop metadata (including
# `stop_hook_active` and `last_assistant_message`), not the submitted prompt.
# The two hook processes therefore correlate through one current-turn file per
# surface. Start replaces that file with the derived ID; end consumes it, or
# records `unknown` when no start preceded it.
#
# The ID is sha256(discriminator + ":" + prompt_sha256), truncated to 16
# hex characters. The preferred discriminator is Claude's session ID from the
# payload (`session_id`/`sessionId`, including supported nested shapes); the
# surface ID is the fallback. The prompt digest makes it turn-specific, while
# the side file lets Stop recover exactly the same ID without prompt content.
#
# Payloads are accepted either as the first remaining JSON argument or on
# stdin. Deliberately POSIX sh with no jq or bash dependency: a relay host is
# someone else's machine. python3 is used when available for safe JSON parsing
# and quoting; every operation is best-effort and this hook always exits zero.

set -u

MODE="${1:-}"
case "$MODE" in
    --start|--end) shift ;;
    *) exit 0 ;;
esac

# TERMMESH_TEAM is also present in worker panes. The request token is injected
# only into a leader pane, so it is the authoritative gate. Every other pane
# must pay no filesystem or parsing cost and must never observe a hook failure.
[ -n "${TERMMESH_LEADER_REQUEST_TOKEN:-}" ] || exit 0

# Payload delivery: stdin is preferred and is what Claude Code actually uses.
# An argv-delivered payload (Codex style, see agent-notify.sh) is accepted for
# compatibility but is copied out and cleared with `set --` immediately: until
# that happens the whole prompt sits in this process's argv, which any
# same-user process can read out of `ps`. Nothing between the copy and the
# clear may block, or the exposure window widens.
PAYLOAD=""
case "${1:-}" in
    \{*) PAYLOAD="$1"; set -- ;;
esac
if [ -z "$PAYLOAD" ] && [ ! -t 0 ]; then
    PAYLOAD="$(cat 2>/dev/null || true)"
fi

TEAM="${TERMMESH_TEAM:-}"
SURFACE_ID="${TERMMESH_SURFACE_ID:-unknown}"
LOG_DIR="${HOME:-}/.term-mesh/logs"
LOG_FILE="$LOG_DIR/turns.log"

# Surface IDs are UUIDs in term-mesh. Restrict the filename anyway so a bad
# inherited environment cannot escape the log directory.
STATE_KEY="$(printf '%s' "$SURFACE_ID" | tr -cd 'A-Za-z0-9._-' 2>/dev/null || true)"
[ -n "$STATE_KEY" ] || STATE_KEY=unknown
STATE_FILE="$LOG_DIR/.turn-current-$STATE_KEY"
STATE_LOCK="$STATE_FILE.lock"
STATE_LOCK_HELD=0

release_state_lock() {
    if [ "$STATE_LOCK_HELD" -eq 1 ]; then
        rm -rf "$STATE_LOCK" 2>/dev/null || true
        STATE_LOCK_HELD=0
    fi
}

acquire_state_lock() {
    _lock_attempt=0
    while [ "$_lock_attempt" -lt 100 ]; do
        if mkdir "$STATE_LOCK" 2>/dev/null; then
            printf '%s\n' "$$" > "$STATE_LOCK/pid" 2>/dev/null || true
            STATE_LOCK_HELD=1
            return 0
        fi
        _lock_pid="$(cat "$STATE_LOCK/pid" 2>/dev/null || true)"
        if [ -n "$_lock_pid" ] && ! kill -0 "$_lock_pid" 2>/dev/null; then
            rm -rf "$STATE_LOCK" 2>/dev/null || true
            continue
        fi
        _lock_attempt=$((_lock_attempt + 1))
        sleep 0.01
    done
    return 1
}

trap release_state_lock EXIT HUP INT TERM

mkdir -p "$LOG_DIR" 2>/dev/null || exit 0
# The sink holds prompt digests and byte counts, never content, but a digest
# plus a short length is still guessable — so keep it owner-only rather than
# inheriting umask. TeamDataStore uses 0700 for board dirs; match that. The
# first writer to create the file decides its mode, so all three writers set
# 0600 explicitly (Swift passes S_IRUSR|S_IWUSR at open).
chmod 700 "$LOG_DIR" 2>/dev/null || true
umask 077

hash_stream() {
    _turn_hash_output=""
    if command -v shasum >/dev/null 2>&1; then
        _turn_hash_output="$(shasum -a 256 2>/dev/null || true)"
    elif command -v sha256sum >/dev/null 2>&1; then
        _turn_hash_output="$(sha256sum 2>/dev/null || true)"
    elif command -v python3 >/dev/null 2>&1; then
        _turn_hash_output="$(python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null || true)"
    fi
    _turn_hash_output=${_turn_hash_output%% *}
    case "$_turn_hash_output" in
        ''|*[!0-9a-fA-F]*) printf '%s' unavailable ;;
        *) printf '%s' "$_turn_hash_output" ;;
    esac
}

json_string() {
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$1" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read(), ensure_ascii=False), end="")' 2>/dev/null \
            || printf '%s' '""'
    else
        # All generated values are ASCII-safe. Team names are normally simple
        # identifiers; strip JSON syntax/control bytes in the rare no-python
        # fallback rather than risk emitting malformed JSON.
        _turn_safe="$(printf '%s' "$1" | tr -cd 'A-Za-z0-9 ._@:/+-' 2>/dev/null || true)"
        printf '"%s"' "$_turn_safe"
    fi
}

PROMPT_BYTES=0
PROMPT_SHA=unavailable
SESSION_ID=""
TURN_ID=unknown
EVENT=turn_end

if [ "$MODE" = --start ]; then
    EVENT=turn_start
    if command -v python3 >/dev/null 2>&1; then
        PROMPT_BYTES="$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    prompt = data.get("prompt", "") if isinstance(data, dict) else ""
    if not isinstance(prompt, str):
        prompt = ""
except Exception:
    prompt = ""
print(len(prompt.encode("utf-8")))
' 2>/dev/null || true)"
        [ -n "$PROMPT_BYTES" ] || PROMPT_BYTES=0
        SESSION_ID="$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
value = None
if isinstance(data, dict):
    for key in ("session_id", "sessionId"):
        if isinstance(data.get(key), str) and data[key]:
            value = data[key]
            break
    if value is None:
        for parent, keys in (
            ("notification", ("session_id", "sessionId")),
            ("data", ("session_id", "sessionId")),
            ("session", ("id", "session_id", "sessionId")),
            ("context", ("session_id", "sessionId")),
        ):
            nested = data.get(parent)
            if not isinstance(nested, dict):
                continue
            for key in keys:
                if isinstance(nested.get(key), str) and nested[key]:
                    value = nested[key]
                    break
            if value is not None:
                break
if value is not None:
    print(value, end="")
' 2>/dev/null || true)"
        PROMPT_SHA="$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    prompt = data.get("prompt", "") if isinstance(data, dict) else ""
    if not isinstance(prompt, str):
        prompt = ""
except Exception:
    prompt = ""
sys.stdout.buffer.write(prompt.encode("utf-8"))
' 2>/dev/null | hash_stream)"
    fi

    if [ "$PROMPT_SHA" != unavailable ]; then
        _turn_discriminator=${SESSION_ID:-$SURFACE_ID}
        _turn_full_hash="$(printf '%s:%s' "$_turn_discriminator" "$PROMPT_SHA" | hash_stream)"
        if [ "$_turn_full_hash" != unavailable ]; then
            TURN_ID="$(printf '%.16s' "$_turn_full_hash")"
        fi
    fi

    # The state file is a stack, not a slot. Claude can queue input, so a second
    # UserPromptSubmit may arrive on this surface before the first Stop; a slot
    # would let the second start overwrite the first, leaving one start with no
    # end and one end attributed to nothing. Both mis-shapes inflate the very
    # gap this instrument measures, because an unmatched start is indistinguish-
    # able from a turn the leader never reported a route for. Appending instead,
    # and popping the last line at end, keeps turns matched under overlap.
    # Failure stays silent, including the redirection's own stderr.
    if acquire_state_lock; then
        { printf '%s\n' "$TURN_ID" >> "$STATE_FILE"; } 2>/dev/null || true
        release_state_lock
    fi
else
    if acquire_state_lock && [ -f "$STATE_FILE" ]; then
        # Which entry does this Stop close? LIFO alone is wrong whenever the
        # harness folds a mid-turn prompt into the turn already running: that
        # produces two UserPromptSubmit events and ONE Stop, so popping the
        # newest entry closes the absorbed prompt and strands the entry that
        # actually stated a route. The stranded entry can never be closed —
        # every later Stop pops a newer line — so it stays start+route with no
        # end, so the routed turn remains stated but can never link. That
        # inverts the linkage measurement: the turn that reported a route
        # reads as incomplete while the absorbed prompt reads as `unstated`.
        #
        # Prefer the oldest entry that owns a route marker, since a stated
        # route is durable evidence that the leader classified that running
        # turn. With no marker, close the oldest entry: later starts were
        # prompts absorbed into it and do not get their own Stop. An empty stack leaves
        # TURN_ID as "unknown" rather than dropping the record — a turn_end we
        # cannot attribute is still evidence that a turn ended.
        _turn_popped=""
        _turn_marked=""
        _turn_index=0
        _turn_popped_index=0
        _turn_marked_index=0
        while IFS= read -r _turn_line; do
            [ -n "$_turn_line" ] || continue
            _turn_index=$((_turn_index + 1))
            case "$_turn_line" in
                *[!A-Za-z0-9._-]*) _turn_line_key="" ;;
                *) _turn_line_key=$_turn_line ;;
            esac
            if [ -z "$_turn_marked" ] && [ -n "$_turn_line_key" ] && [ -f "$LOG_DIR/.turn-route-$_turn_line_key" ]; then
                _turn_marked="$_turn_line"
                _turn_marked_index=$_turn_index
            fi
            if [ -z "$_turn_popped" ]; then
                _turn_popped="$_turn_line"
                _turn_popped_index=$_turn_index
            fi
        done < "$STATE_FILE" 2>/dev/null
        if [ -n "$_turn_marked" ]; then
            _turn_popped="$_turn_marked"
            _turn_popped_index=$_turn_marked_index
        fi
        [ -n "$_turn_popped" ] && TURN_ID="$_turn_popped"
        # Remove only the chosen entry, keeping every other line and its order.
        # Deleting the last line unconditionally would drop a still-open turn
        # whenever the marked entry was not the newest one.
        if [ -n "$_turn_popped" ]; then
            _turn_absorbed=""
            rm -f "$STATE_FILE.absorbed.$$" 2>/dev/null || true
            _turn_rest="$(
                _turn_index=0
                while IFS= read -r _turn_line; do
                    [ -n "$_turn_line" ] || continue
                    _turn_index=$((_turn_index + 1))
                    if [ "$_turn_index" -eq "$_turn_popped_index" ]; then
                        continue
                    fi
                    if [ "$_turn_index" -gt "$_turn_popped_index" ]; then
                        printf '%s\n' "$_turn_line" >> "$STATE_FILE.absorbed.$$"
                        continue
                    fi
                    printf '%s\n' "$_turn_line"
                done < "$STATE_FILE" 2>/dev/null
            )"
            _turn_absorbed="$(cat "$STATE_FILE.absorbed.$$" 2>/dev/null || true)"
            rm -f "$STATE_FILE.absorbed.$$" 2>/dev/null || true
        else
            _turn_absorbed=""
            _turn_rest=""
        fi
        if [ -n "$_turn_rest" ]; then
            _turn_state_tmp="$STATE_FILE.tmp.$$"
            if { printf '%s\n' "$_turn_rest" > "$_turn_state_tmp"; } 2>/dev/null; then
                mv -f "$_turn_state_tmp" "$STATE_FILE" 2>/dev/null || true
            else
                rm -f "$_turn_state_tmp" 2>/dev/null || true
            fi
        else
            rm -f "$STATE_FILE" 2>/dev/null || true
        fi
    fi
    release_state_lock
fi

# A route command creates this short-lived marker after it appends its own
# turn_route record. Reading a marker is safer than searching a log another
# process may append to or that GC may rotate between the search and the end.
ROUTE_STATUS=""
if [ "$MODE" = --end ]; then
    ROUTE_KEY="$(printf '%s' "$TURN_ID" | tr -cd 'A-Za-z0-9._-' 2>/dev/null || true)"
    if [ -n "$ROUTE_KEY" ] && [ -f "$LOG_DIR/.turn-route-$ROUTE_KEY" ]; then
        ROUTE_STATUS=stated
        rm -f "$LOG_DIR/.turn-route-$ROUTE_KEY" 2>/dev/null || true
    else
        ROUTE_STATUS=unstated
    fi
fi

TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
[ -n "$TS" ] || TS=unknown

# Did this turn meet the delegation floor? Only `delegated` states a floor that
# a turn can measurably miss, and `task_dispatch` is written by the app rather
# than claimed by the leader, so this is the one participation signal that does
# not depend on the leader choosing to report anything. Anything unreadable
# leaves the field off entirely rather than guessing "met".
DELEGATION_FLOOR=""
if [ "$MODE" = --end ] \
    && [ "$TURN_ID" != unknown ] \
    && [ -n "${TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE:-}" ] \
    && [ -r "${TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE:-}" ] \
    && [ -r "$LOG_FILE" ] \
    && command -v python3 >/dev/null 2>&1; then
    DELEGATION_FLOOR="$(python3 - "$TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE" "$LOG_FILE" "$TURN_ID" <<'TURN_HOOK_MET' 2>/dev/null || true
import json
import sys

control_path, log_path, turn_id = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(control_path, "r", encoding="utf-8") as handle:
        control = json.load(handle)
except Exception:
    sys.exit(0)

if not isinstance(control, dict) or control.get("kill_switch") is True:
    sys.exit(0)

level = control.get("delegation_effective") or control.get("delegation_configured")
try:
    workers = int(control.get("available_workers") or 0)
except (TypeError, ValueError):
    workers = 0
if level != "delegated" or workers <= 0:
    sys.exit(0)

# task_dispatch carries a request/wave/task id, never this turn's id, so the
# two streams cannot be joined by key. Walking back to this turn's own start is
# the join: whatever dispatch records lie after it belong to this turn. Read a
# bounded tail so a rotated-but-large log cannot stall a Stop hook.
try:
    with open(log_path, "r", encoding="utf-8") as handle:
        lines = handle.readlines()[-4000:]
except Exception:
    sys.exit(0)

dispatched = False
for line in reversed(lines):
    line = line.strip()
    if not line:
        continue
    try:
        record = json.loads(line)
    except Exception:
        continue
    if not isinstance(record, dict):
        continue
    event = record.get("event")
    if event == "turn_start" and record.get("turn_id") == turn_id:
        print("met" if dispatched else "unmet", end="")
        sys.exit(0)
    if event == "task_dispatch":
        dispatched = True

# No start found in the tail: say nothing rather than call an unbounded window
# unmet.
TURN_HOOK_MET
)"
    case "$DELEGATION_FLOOR" in
        met|unmet) ;;
        *) DELEGATION_FLOOR="" ;;
    esac
fi

# Entries newer than the routed turn were prompts absorbed into that running
# turn. Record and remove them explicitly so health metrics do not count them
# as independent turns that can never acquire a route or Stop.
if [ "$MODE" = --end ] && [ -n "${_turn_absorbed:-}" ]; then
    while IFS= read -r _turn_absorbed_id; do
        [ -n "$_turn_absorbed_id" ] || continue
        _turn_absorbed_line="{\"event\":\"turn_end\",\"turn_id\":$(json_string "$_turn_absorbed_id"),\"ts\":$(json_string "$TS"),\"team\":$(json_string "$TEAM"),\"surface_id\":$(json_string "$SURFACE_ID"),\"route_status\":\"absorbed\"}"
        { printf '%s\n' "$_turn_absorbed_line" >> "$LOG_FILE"; } 2>/dev/null || true
    done <<EOF
$_turn_absorbed
EOF
fi

if [ "$MODE" = --start ]; then
    LINE="{\"event\":$(json_string "$EVENT"),\"turn_id\":$(json_string "$TURN_ID"),\"ts\":$(json_string "$TS"),\"team\":$(json_string "$TEAM"),\"surface_id\":$(json_string "$SURFACE_ID"),\"prompt_bytes\":$PROMPT_BYTES,\"prompt_sha256\":$(json_string "$PROMPT_SHA")}"
else
    FLOOR_FIELD=""
    if [ -n "$DELEGATION_FLOOR" ]; then
        FLOOR_FIELD=",\"delegation_floor\":$(json_string "$DELEGATION_FLOOR")"
    fi
    LINE="{\"event\":$(json_string "$EVENT"),\"turn_id\":$(json_string "$TURN_ID"),\"ts\":$(json_string "$TS"),\"team\":$(json_string "$TEAM"),\"surface_id\":$(json_string "$SURFACE_ID"),\"route_status\":$(json_string "$ROUTE_STATUS")$FLOOR_FIELD}"
fi

# Open the append once per invocation and emit one complete line. Do not retain
# this FD: daemon GC rotates turns.log at startup and every six hours, and a
# retained descriptor would keep writing to the renamed inode.
{ printf '%s\n' "$LINE" >> "$LOG_FILE"; } 2>/dev/null || true

# The delegation floor. Everything above this line observes; this block is the
# only part that speaks back, and stdout is the reason it can: Claude Code adds
# a UserPromptSubmit hook's stdout to the turn's context, which makes this the
# one request boundary that a directly typed prompt cannot bypass. It restates
# the Project's own configured level and the roster the app already wrote into
# the control file — it never decides anything the app did not already decide.
#
# Every failure is silent and empty. A missing, unreadable, or malformed control
# file, absent python3, a zero roster, or an engaged kill switch all leave stdout
# untouched, because a hook that garbles a leader turn costs more than a hook
# that says nothing. Stop's stdout is not injected, so only --start emits.
if [ "$MODE" = --start ] \
    && [ -n "${TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE:-}" ] \
    && [ -r "${TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE:-}" ] \
    && command -v python3 >/dev/null 2>&1; then
    python3 - "$TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE" <<'TURN_HOOK_FLOOR' 2>/dev/null || true
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        control = json.load(handle)
except Exception:
    sys.exit(0)

if not isinstance(control, dict) or control.get("kill_switch") is True:
    sys.exit(0)

# The per-Project switch for this whole block. Off restores the pre-existing
# behavior — the leader decides unaided. Measurement is unaffected: observing
# what a turn did is not the same as telling it what to do.
if control.get("inject_directive") is False:
    sys.exit(0)

level = control.get("delegation_effective") or control.get("delegation_configured")
if not isinstance(level, str):
    sys.exit(0)

try:
    workers = int(control.get("available_workers") or 0)
except (TypeError, ValueError):
    workers = 0
if workers <= 0:
    sys.exit(0)

try:
    cap = int(control.get("max_parallel_workers") or 3)
except (TypeError, ValueError):
    cap = 3
cap = max(1, cap)
# What a wave can actually be here: never more than the roster, never more than
# the Project allows. A cap of one means waves are off, not that they are small.
wave = min(cap, workers)

names = control.get("worker_names")
names = [n for n in names if isinstance(n, str) and n] if isinstance(names, list) else []

# leaderFirst only has something to say when a wave is possible at all: it
# leaves serial work with the leader either way, so with no wave available the
# floor would repeat the default every turn as noise.
if level == "leaderFirst" and wave < 2:
    sys.exit(0)

if wave >= 2:
    wave_clause = (
        "Prefer a parallel wave of up to {} workers whenever at least two units are "
        "dependency-ready, independently verifiable, and ownership-disjoint.".format(wave)
    )
else:
    wave_clause = (
        "Parallel waves are off for this Project, so keep the work in one lane."
    )

FLOORS = {
    "leaderFirst": (
        wave_clause
        + " Direct execution stays available for trivial, same-file, or "
        "dependency-serial work."
    ),
    "guarded": (
        "Serial work stays in the leader lane, but a risk condition (cross-subsystem, "
        "protocol or persistence, irreversible or release, unverified core assumption, "
        "repeated failure) spends exactly one read-only worker probe first. "
        + wave_clause
    ),
    "delegated": (
        "Hand serial implementation to a worker and keep coordination, integration, and "
        "review in the leader lane. Implementing it yourself requires a reason recorded "
        "with `tm-agent leader turn route`. " + wave_clause
    ),
}
floor = FLOORS.get(level)
if floor is None:
    sys.exit(0)

project = control.get("project_id")
project = project if isinstance(project, str) and project else "this Project"
roster = " ({})".format(", ".join(names[:8])) if names else ""

print(
    "[term-mesh] Delegation floor for this turn — project: {}, level: {}, "
    "workers available: {}{}, max parallel: {}".format(
        project, level, workers, roster, cap
    )
)
print(floor)
TURN_HOOK_FLOOR
fi

exit 0
