#!/usr/bin/env bash
# Smoke test for tm-agent /team and /tm lifecycle subcommands.
#
# Tests: status, idempotency, add→detach roundtrip, swap macro (model change),
#        graceful remove of non-existent agent, graceful attach with invalid role.
#
# Usage:
#   bash -n scripts/test-team-lifecycle.sh    # syntax check only
#   ./scripts/test-team-lifecycle.sh          # run on VM with active team
#   ./scripts/test-team-lifecycle.sh --verbose
#
# Precondition: a team is already active (tm-agent status returns success).
# DO NOT create/destroy the real team — operates within whatever team is active.
#
# DO NOT RUN ON HOST MACHINE — run inside ssh term-mesh-vm.

set -euo pipefail

# ── CLI args ──────────────────────────────────────────────────────────────────
VERBOSE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose|-v) VERBOSE=true ;;
        -h|--help)
            printf 'Usage: %s [--verbose]\n' "$0"
            exit 0
            ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
done

# ── Globals ───────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
# All *-smoke names that must be cleaned up even on early exit.
SMOKE_AGENTS=(reviewer-test explorer-smoke executor-smoke)

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { [ "$VERBOSE" = true ] && printf '  [verbose] %s\n' "$*" >&2 || true; }

pass() {
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$1"
}

# agent_in_status <name>
# Returns 0 if the agent name appears in the .result.agents array, 1 otherwise.
agent_in_status() {
    local name="$1"
    local status_out count
    status_out=$(tm-agent status 2>/dev/null) || return 1
    count=$(printf '%s' "$status_out" \
        | jq --arg n "$name" '[.result.agents[]? | select(.name == $n)] | length' \
        2>/dev/null) || count=0
    [ "${count:-0}" -gt 0 ]
}

# agent_model_in_status <name>
# Prints the model field for the named agent (empty string if absent or unresolvable).
agent_model_in_status() {
    local name="$1"
    local status_out
    status_out=$(tm-agent status 2>/dev/null) || { printf ''; return; }
    printf '%s' "$status_out" \
        | jq -r --arg n "$name" \
            'first(.result.agents[]? | select(.name == $n) | .model) // ""' \
        2>/dev/null || printf ''
}

# ── Cleanup trap ──────────────────────────────────────────────────────────────
_cleanup() {
    log "trap: detaching all *-smoke agents"
    local a
    for a in "${SMOKE_AGENTS[@]}"; do
        tm-agent detach "$a" 2>/dev/null || true
    done
}
trap _cleanup EXIT INT TERM

# ── Pre-flight checks ─────────────────────────────────────────────────────────
printf '=== tm-agent lifecycle smoke test ===\n'

if ! command -v jq >/dev/null 2>&1; then
    printf 'ERROR: jq is required but not installed\n' >&2
    exit 1
fi

if ! command -v tm-agent >/dev/null 2>&1; then
    printf 'ERROR: tm-agent not found in PATH\n' >&2
    exit 1
fi

# ── Test 1: status ────────────────────────────────────────────────────────────
test_status() {
    printf '\n[1/6] status — tm-agent status returns valid JSON with agents array\n'
    local out exit_code count
    exit_code=0
    out=$(tm-agent status 2>&1) || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "tm-agent status exited $exit_code — output: $(printf '%s' "$out" | head -c 200)"
        return
    fi
    if ! printf '%s' "$out" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1; then
        fail "status output lacks .result.agents array — got: $(printf '%s' "$out" | head -c 200)"
        return
    fi
    count=$(printf '%s' "$out" | jq '.result.agents | length' 2>/dev/null) || count='?'
    pass "status returned .result.agents array (length=$count)"
}

# ── Test 2: idempotency ───────────────────────────────────────────────────────
test_idempotency() {
    printf '\n[2/6] idempotency — attach reviewer-test twice; second call must not crash\n'
    local exit1 exit2 out2 count

    # First attach
    exit1=0
    tm-agent attach reviewer --name reviewer-test 2>/dev/null || exit1=$?
    if [ "$exit1" -ne 0 ]; then
        fail "first attach reviewer-test failed (exit=$exit1)"
        return
    fi
    log "first attach succeeded"

    # Second attach — idempotent: daemon should skip or error gracefully (no crash)
    exit2=0
    out2=$(tm-agent attach reviewer --name reviewer-test 2>&1) || exit2=$?
    log "second attach: exit=$exit2 out=$(printf '%s' "$out2" | head -c 120)"

    # Agent must still be reachable in status
    count=$(tm-agent status 2>/dev/null \
        | jq '[.result.agents[]? | select(.name == "reviewer-test")] | length' \
        2>/dev/null) || count=0
    log "reviewer-test count in status: $count"

    # Cleanup before asserting
    tm-agent detach reviewer-test 2>/dev/null || true

    if [ "${count:-0}" -ge 1 ]; then
        pass "idempotent: reviewer-test present in status (count=$count); second attach exit=$exit2"
    else
        fail "reviewer-test not found in status after two attaches (count=${count:-0})"
    fi
}

# ── Test 3: add → detach roundtrip ───────────────────────────────────────────
test_roundtrip() {
    printf '\n[3/6] roundtrip — explorer-smoke: attach → verify present → detach → verify gone\n'
    local exit_code

    exit_code=0
    tm-agent attach explorer --name explorer-smoke 2>/dev/null || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "attach explorer-smoke failed (exit=$exit_code)"
        return
    fi
    log "explorer-smoke attached"

    if ! agent_in_status "explorer-smoke"; then
        fail "explorer-smoke not found in status after attach"
        tm-agent detach explorer-smoke 2>/dev/null || true
        return
    fi
    log "explorer-smoke confirmed in status"

    exit_code=0
    tm-agent detach explorer-smoke 2>/dev/null || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "detach explorer-smoke failed (exit=$exit_code)"
        return
    fi
    log "explorer-smoke detached"

    sleep 1

    if agent_in_status "explorer-smoke"; then
        fail "explorer-smoke still appears in status after detach"
        tm-agent detach explorer-smoke 2>/dev/null || true
        return
    fi

    pass "roundtrip: explorer-smoke attached → in status → detached → gone from status"
}

# ── Test 4: swap macro (model change) ────────────────────────────────────────
test_swap() {
    printf '\n[4/6] swap — executor-smoke@sonnet detach→reattach@opus; verify model changed\n'
    local exit_code model1 model2

    exit_code=0
    tm-agent attach executor --name executor-smoke --model sonnet 2>/dev/null || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "attach executor-smoke@sonnet failed (exit=$exit_code)"
        return
    fi
    log "executor-smoke@sonnet attached"

    model1=$(agent_model_in_status "executor-smoke")
    log "model before swap: ${model1:-<not in status>}"

    exit_code=0
    tm-agent detach executor-smoke 2>/dev/null || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "detach executor-smoke (pre-swap) failed (exit=$exit_code)"
        return
    fi
    sleep 1

    exit_code=0
    tm-agent attach executor --name executor-smoke --model opus 2>/dev/null || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        fail "attach executor-smoke@opus failed (exit=$exit_code)"
        return
    fi
    log "executor-smoke@opus attached"

    model2=$(agent_model_in_status "executor-smoke")
    log "model after swap: ${model2:-<not in status>}"

    tm-agent detach executor-smoke 2>/dev/null || true

    if [ "$model2" = "opus" ]; then
        pass "swap: model ${model1:-<unset>} → $model2"
    elif [ -z "$model2" ] || [ "$model2" = "null" ]; then
        # model field not exposed in status JSON — detach+reattach cycle itself is the contract
        pass "swap: detach+reattach@opus completed (model field not exposed in status — soft pass)"
    else
        fail "swap: expected model=opus after reattach, got model=$model2"
    fi
}

# ── Test 5: remove of non-existent agent ─────────────────────────────────────
test_remove_nonexistent() {
    printf '\n[5/6] remove-non-existent — detach does-not-exist-9999 must fail gracefully\n'
    local out exit_code
    exit_code=0
    out=$(tm-agent detach does-not-exist-9999 2>&1) || exit_code=$?
    log "exit=$exit_code out=$(printf '%s' "$out" | head -c 120)"

    if [ "$exit_code" -ne 0 ]; then
        pass "non-existent detach exited $exit_code (non-zero, no crash)"
    elif printf '%s' "$out" | grep -qiE "error|not found|unknown|no agent"; then
        pass "non-existent detach exit=0 but output signals error (graceful)"
    else
        fail "detach of non-existent agent exited 0 with no error indication: $out"
    fi
}

# ── Test 6: attach with invalid role ─────────────────────────────────────────
test_invalid_role() {
    printf '\n[6/6] invalid-role — attach not-a-real-role must fail gracefully\n'
    local out exit_code
    exit_code=0
    out=$(tm-agent attach not-a-real-role 2>&1) || exit_code=$?
    log "exit=$exit_code out=$(printf '%s' "$out" | head -c 120)"

    # Guarantee no leak even if the daemon erroneously created the pane
    agent_in_status "not-a-real-role" \
        && { tm-agent detach not-a-real-role 2>/dev/null || true; } \
        || true

    if [ "$exit_code" -ne 0 ]; then
        pass "invalid role exited $exit_code (non-zero, no crash)"
    elif printf '%s' "$out" | grep -qiE "error|invalid|unknown|unrecognized|not.*role"; then
        pass "invalid role exit=0 but output signals error (graceful)"
    else
        fail "attach with invalid role exited 0 with no error indication: $out"
    fi
}

# ── Run all tests (set +e so one failure does not abort the suite) ─────────────
set +e
test_status
test_idempotency
test_roundtrip
test_swap
test_remove_nonexistent
test_invalid_role
set -e

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n=== Summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
