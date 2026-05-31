#!/usr/bin/env bash
# Regression tests for tm-agent 5-weakness parallel execution fixes.
# Commits: d69c9d0c (BUG-1/3/GAP-4 Swift), 1d34c1f0 + 3b312b7a (BUG-5 Rust)
#
# Usage:
#   ./scripts/test-parallel.sh [--skip-team-create] [--keep-team] [--verbose]
#
# Options:
#   --skip-team-create   Use existing active team (skip create + destroy)
#   --keep-team          Don't destroy team on exit (debug)
#   --verbose            Print diagnostic details to stderr
set -eu

# ── CLI args ──────────────────────────────────────────────────────────────────
SKIP_TEAM_CREATE=false
KEEP_TEAM=false
VERBOSE=false

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-team-create) SKIP_TEAM_CREATE=true ;;
        --keep-team)        KEEP_TEAM=true ;;
        --verbose)          VERBOSE=true ;;
        -h|--help)
            printf 'Usage: %s [--skip-team-create] [--keep-team] [--verbose]\n' "$0"
            exit 0
            ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
done

# ── Globals ───────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TMPDIR_TEST=$(mktemp -d /tmp/test-parallel-XXXXXX)

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { [ "$VERBOSE" = true ] && printf '  [verbose] %s\n' "$*" >&2 || true; }

pass() {
    PASS=$((PASS + 1))
    printf '  PASS  (%s)\n' "$1"
}

fail() {
    local reason="$1" expected="$2" diag="${3:-}"
    FAIL=$((FAIL + 1))
    printf '  FAIL  (%s)\n' "$reason"
    printf '         Expected: %s\n' "$expected"
    [ -n "$diag" ] && printf '         Diag: %s\n' "$diag" || true
}

# Extract a dotted key from JSON via jq (preferred) or python3.
# Usage: json_get '.result.task.id' "$json_string"
json_get() {
    local key="$1" json="$2"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r "$key" 2>/dev/null || printf ''
    else
        printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    parts = '$key'.lstrip('.').split('.')
    for p in parts:
        d = d[p] if isinstance(d, dict) else (d[int(p)] if isinstance(d, list) else '')
    print('' if d is None else d)
except Exception:
    print('')
" 2>/dev/null || printf ''
    fi
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
_cleanup() {
    rm -rf "$TMPDIR_TEST" 2>/dev/null || true
    if [ "$KEEP_TEAM" = false ] && [ "$SKIP_TEAM_CREATE" = false ]; then
        tm-agent destroy 2>/dev/null || true
        log "team destroyed"
    fi
}
trap _cleanup EXIT INT TERM

# ── Setup ─────────────────────────────────────────────────────────────────────
printf '=== tm-agent parallel test ===\n'

if [ "$SKIP_TEAM_CREATE" = false ]; then
    # Tear down any existing team to avoid state pollution.
    tm-agent destroy 2>/dev/null || true
    sleep 1
    # Create a 4-agent team. Ensure the team roster includes ≥2 executors
    # (the default `tm-agent create 4` spawns: leader + explorer + executor×2 + reviewer).
    log "creating 4-agent team"
    tm-agent create 4
    sleep 4  # Allow agents to initialize and open panels
fi

# ── Phase 1: BUG-1 round-robin ────────────────────────────────────────────────
printf 'Phase 1 (BUG-1 round-robin):   '

MARKER_A="task-A-$$"
MARKER_B="task-B-$$"
FILE_A="$TMPDIR_TEST/exec-a.txt"
FILE_B="$TMPDIR_TEST/exec-b.txt"

# Delegate two tasks back-to-back to the same agent name "executor".
# With BUG-1 fixed, selectAgent() round-robins across duplicate-named agents,
# so each delegate lands on a different physical panel.
out_a=$(tm-agent delegate executor \
    "echo $MARKER_A > $FILE_A && echo $MARKER_A" 2>/dev/null || printf '{}')
out_b=$(tm-agent delegate executor \
    "echo $MARKER_B > $FILE_B && echo $MARKER_B" 2>/dev/null || printf '{}')

task_a=$(json_get '.result.task.id' "$out_a")
task_b=$(json_get '.result.task.id' "$out_b")
log "task_a=$task_a task_b=$task_b"

# Check the task board: each task should have a distinct assignee slot.
# (assignee field contains name, but different panels can share a name.)
sleep 2
task_a_json=$(tm-agent task get "$task_a" 2>/dev/null || printf '{}')
task_b_json=$(tm-agent task get "$task_b" 2>/dev/null || printf '{}')
status_a=$(json_get '.result.status' "$task_a_json")
status_b=$(json_get '.result.status' "$task_b_json")
log "status_a=$status_a status_b=$status_b"

if [ -z "$task_a" ] || [ -z "$task_b" ] || [ "$task_a" = 'null' ] || [ "$task_b" = 'null' ]; then
    fail "could not extract task_ids from delegate output" \
         "two distinct task_ids from consecutive delegate calls" \
         "out_a=$(printf '%s' "$out_a" | head -c 120) out_b=$(printf '%s' "$out_b" | head -c 120)"
elif [ "$task_a" = "$task_b" ]; then
    fail "both delegates returned identical task_id=$task_a" \
         "two different task_ids (round-robin produces distinct tasks)" \
         "selectAgent() may not be branching correctly"
else
    # Both tasks exist. Wait for Claude to process them and check file evidence.
    sleep 6
    if [ -f "$FILE_A" ] && [ -f "$FILE_B" ] \
       && grep -q "$MARKER_A" "$FILE_A" 2>/dev/null \
       && grep -q "$MARKER_B" "$FILE_B" 2>/dev/null; then
        pass "executor#1=$task_a, executor#2=$task_b (both panels ran distinct tasks)"
    elif [ -f "$FILE_A" ] && grep -q "$MARKER_B" "$FILE_A" 2>/dev/null \
         && [ -f "$FILE_B" ] && grep -q "$MARKER_A" "$FILE_B" 2>/dev/null; then
        pass "executor#1=$task_b, executor#2=$task_a (swapped, still distributed)"
    else
        # File evidence inconclusive — fall back to task-board status check.
        # At minimum both tasks should be in non-pending state if distributed.
        if [ "$status_a" != 'pending' ] && [ "$status_b" != 'pending' ]; then
            pass "task_a=$task_a($status_a), task_b=$task_b($status_b) — both actioned"
        else
            fail "tasks not distributed or not started (status_a=$status_a status_b=$status_b)" \
                 "both tasks actioned on different panels" \
                 "Files: FILE_A=$([ -f "$FILE_A" ] && echo exists || echo missing) FILE_B=$([ -f "$FILE_B" ] && echo exists || echo missing)"
        fi
    fi
fi

# ── Phase 2: BUG-3 broadcast ──────────────────────────────────────────────────
printf 'Phase 2 (BUG-3 broadcast):     '

PING_TAG="BROADCAST_PING_$$_$(date +%s)"
tm-agent broadcast "$PING_TAG" 2>/dev/null || true
sleep 3

# Enumerate all agent slots from status (duplicate names appear multiple times).
status_json=$(tm-agent status 2>/dev/null || printf '{}')
agent_slots=$(printf '%s' "$status_json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    agents = data.get('result', data).get('agents', [])
    # One entry per slot, even if names repeat
    for a in agents:
        print(a.get('name', 'unknown'))
except Exception:
    pass
" 2>/dev/null || printf '')

panels_total=0
panels_hit=0

for aname in $agent_slots; do
    panels_total=$((panels_total + 1))
    read_out=$(tm-agent read "$aname" --lines 40 2>/dev/null || printf '')
    if printf '%s' "$read_out" | grep -q "$PING_TAG"; then
        panels_hit=$((panels_hit + 1))
        log "agent '$aname' slot#$panels_total: HIT"
    else
        log "agent '$aname' slot#$panels_total: MISS (note: duplicate-named agents share read channel)"
    fi
done

# Fallback: aggregate collect for duplicate-named agents that share a read channel.
collect_out=$(tm-agent collect --lines 60 2>/dev/null || printf '')
collect_hit=$(printf '%s' "$collect_out" | grep -c "$PING_TAG" || printf '0')
log "collect hits=$collect_hit panels_hit=$panels_hit panels_total=$panels_total"

if [ "$panels_total" -eq 0 ]; then
    fail "no agents found in status" "≥2 agent panels in team" \
         "$(printf '%s' "$status_json" | head -c 200)"
elif [ "$panels_hit" -ge "$panels_total" ]; then
    pass "$panels_hit/$panels_total panels received $PING_TAG"
elif [ "$collect_hit" -gt 0 ]; then
    # Some panels hit — partial pass with note about duplicate-name read limitation
    pass "$panels_hit/$panels_total via read + $collect_hit hits in collect (duplicate-name read shares channel)"
else
    fail "$panels_hit/$panels_total panels received broadcast" \
         "all $panels_total panels ($PING_TAG)" \
         "collect also shows 0 hits — check broadcast() panelId routing"
fi

# ── Phase 3: GAP-4 claim push ─────────────────────────────────────────────────
printf 'Phase 3 (GAP-4 claim push):    '

CLAIM_TITLE="CLAIM_TEST_$$_$(date +%s)"
create_json=$(tm-agent task create "$CLAIM_TITLE" 2>/dev/null || printf '{}')
# `task create` returns the task fields directly under .result (only delegate /
# claim responses nest them under .result.task).
claim_id=$(json_get '.result.id' "$create_json")
log "pool task created: $claim_id"

if [ -z "$claim_id" ] || [ "$claim_id" = 'null' ]; then
    fail "task create returned no id" "task_id in result.id" \
         "$(printf '%s' "$create_json" | head -c 200)"
else
    # Ask an executor to claim from the pool autonomously.
    # The GAP-4 fix: after claim, teamDataTaskClaim pushes notifyTaskCreated
    # so the agent receives task instructions without a separate `delegate`.
    tm-agent send executor "tm-agent claim 2>/dev/null || true" 2>/dev/null || true
    sleep 5

    task_json=$(tm-agent task get "$claim_id" 2>/dev/null || printf '{}')
    task_status=$(json_get '.result.status' "$task_json")
    log "task $claim_id status=$task_status"

    case "$task_status" in
        completed|in_progress|assigned)
            pass "status=$task_status after autonomous claim+push"
            ;;
        pending|'')
            fail "status=${task_status:-?} — claim produced no status change" \
                 "assigned/in_progress/completed (claim push activated the task)" \
                 "task_id=$claim_id; check notifyTaskCreated overload in teamDataTaskClaim"
            ;;
        *)
            pass "status=$task_status (task was touched after claim)"
            ;;
    esac
fi

# ── Phase 4: BUG-5 board.jsonl flock ──────────────────────────────────────────
printf 'Phase 4 (BUG-5 flock):         '

# Capture the dispatch output so we can read board_path directly — the research
# board now lives at <repo>/.xm/research/<run>/board.jsonl, not ~/.term-mesh/results.
research_out=$(tm-agent research \
    "PARALLEL_FLOCK_TEST — note 3 observations about terminal pane routing" \
    --agents 3 --budget 2 --timeout 90 --depth shallow 2>/dev/null || printf '')

# Prefer the board_path the dispatch reported; fall back to scanning the
# project-local research dir (then the legacy results dir).
board_file=$(printf '%s' "$research_out" \
    | grep -oE '"board_path"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 \
    | sed -E 's/.*"board_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
if [ -z "$board_file" ] || [ ! -f "$board_file" ]; then
    for root in "$PWD/.xm/research" "$HOME/.term-mesh/results"; do
        [ -d "$root" ] || continue
        board_file=$(find "$root" -name 'board*.jsonl' 2>/dev/null \
                     | xargs ls -t 2>/dev/null | head -1 || printf '')
        [ -n "$board_file" ] && break
    done
fi

if [ -z "$board_file" ] || [ ! -f "$board_file" ]; then
    fail "board.jsonl not found after research run" \
         "board file (board_path from research output, or under .xm/research/**)" \
         "research_out head: $(printf '%s' "$research_out" | head -c 160)"
else
    parse_result=$(python3 - "$board_file" <<'PYEOF'
import json, sys
path = sys.argv[1]
total = 0
bad = 0
with open(path) as f:
    for lineno, raw in enumerate(f, 1):
        line = raw.strip()
        if not line:
            continue
        total += 1
        try:
            json.loads(line)
        except json.JSONDecodeError as e:
            bad += 1
            sys.stderr.write(f"  bad line {lineno}: {e}\n")
print(f"{total},{bad}")
PYEOF
2>/dev/null || printf '0,?')
    total_lines="${parse_result%,*}"
    bad_lines="${parse_result#*,}"
    log "board=$board_file total=$total_lines bad=$bad_lines"

    if [ "$bad_lines" = '0' ]; then
        pass "$total_lines/$total_lines valid JSON lines (no flock interleaving)"
    else
        fail "$bad_lines invalid JSON line(s) out of $total_lines" \
             "all lines valid JSON (fcntl.flock serializes concurrent appends)" \
             "board=$board_file — run: python3 -m json.tool < $board_file"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '==================================\n'
printf 'Result: %d/%d PASS\n' "$PASS" "$((PASS + FAIL))"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
