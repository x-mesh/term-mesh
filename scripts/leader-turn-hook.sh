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
    { printf '%s\n' "$TURN_ID" >> "$STATE_FILE"; } 2>/dev/null || true
else
    if [ -f "$STATE_FILE" ]; then
        # Which entry does this Stop close? LIFO alone is wrong whenever the
        # harness folds a mid-turn prompt into the turn already running: that
        # produces two UserPromptSubmit events and ONE Stop, so popping the
        # newest entry closes the absorbed prompt and strands the entry that
        # actually stated a route. The stranded entry can never be closed —
        # every later Stop pops a newer line — so it stays start+route with no
        # end, which `health()` counts in no outcome cohort at all and can
        # never link. That inverts the measurement: the turn that reported a
        # route reads as incomplete while the one that did not reads as
        # `unstated`.
        #
        # Prefer the newest entry that owns a route marker, since a stated
        # route is durable evidence that the leader classified that turn and is
        # the pairing worth preserving. With no marker anywhere, fall back to
        # plain LIFO (the innermost turn ends first). An empty stack leaves
        # TURN_ID as "unknown" rather than dropping the record — a turn_end we
        # cannot attribute is still evidence that a turn ended.
        _turn_popped=""
        _turn_marked=""
        while IFS= read -r _turn_line; do
            [ -n "$_turn_line" ] || continue
            _turn_line_key="$(printf '%s' "$_turn_line" | tr -cd 'A-Za-z0-9._-' 2>/dev/null || true)"
            if [ -n "$_turn_line_key" ] && [ -f "$LOG_DIR/.turn-route-$_turn_line_key" ]; then
                _turn_marked="$_turn_line"
            fi
            _turn_popped="$_turn_line"
        done < "$STATE_FILE"
        [ -n "$_turn_marked" ] && _turn_popped="$_turn_marked"
        [ -n "$_turn_popped" ] && TURN_ID="$_turn_popped"
        # Remove only the chosen entry, keeping every other line and its order.
        # Deleting the last line unconditionally would drop a still-open turn
        # whenever the marked entry was not the newest one.
        if [ -n "$_turn_popped" ]; then
            _turn_rest="$(
                _turn_dropped=0
                while IFS= read -r _turn_line; do
                    if [ "$_turn_dropped" -eq 0 ] && [ "$_turn_line" = "$_turn_popped" ]; then
                        _turn_dropped=1
                        continue
                    fi
                    printf '%s\n' "$_turn_line"
                done < "$STATE_FILE"
            )"
        else
            _turn_rest=""
        fi
        if [ -n "$_turn_rest" ]; then
            { printf '%s\n' "$_turn_rest" > "$STATE_FILE"; } 2>/dev/null || true
        else
            rm -f "$STATE_FILE" 2>/dev/null || true
        fi
    fi
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

if [ "$MODE" = --start ]; then
    LINE="{\"event\":$(json_string "$EVENT"),\"turn_id\":$(json_string "$TURN_ID"),\"ts\":$(json_string "$TS"),\"team\":$(json_string "$TEAM"),\"surface_id\":$(json_string "$SURFACE_ID"),\"prompt_bytes\":$PROMPT_BYTES,\"prompt_sha256\":$(json_string "$PROMPT_SHA")}"
else
    LINE="{\"event\":$(json_string "$EVENT"),\"turn_id\":$(json_string "$TURN_ID"),\"ts\":$(json_string "$TS"),\"team\":$(json_string "$TEAM"),\"surface_id\":$(json_string "$SURFACE_ID"),\"route_status\":$(json_string "$ROUTE_STATUS")}"
fi

# Open the append once per invocation and emit one complete line. Do not retain
# this FD: daemon GC rotates turns.log at startup and every six hours, and a
# retained descriptor would keep writing to the renamed inode.
{ printf '%s\n' "$LINE" >> "$LOG_FILE"; } 2>/dev/null || true
exit 0
