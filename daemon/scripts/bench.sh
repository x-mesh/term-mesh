#!/usr/bin/env bash
# bench.sh — PRD Section 7 Performance Benchmark for term-meshd
#
# Prerequisites:
#   - term-meshd running (cd daemon && cargo run --bin term-meshd)
#   - socat installed (brew install socat)
#   - curl available
#
# Usage:
#   bash daemon/scripts/bench.sh

set -euo pipefail

PORT=${TERM_MESH_HTTP_PORT:-9876}
SOCK="${TMPDIR:-/tmp}/term-meshd.sock"
PASS=0
FAIL=0
SKIP=0

# ── Helpers ──

green()  { printf "\033[32m%s\033[0m" "$1"; }
red()    { printf "\033[31m%s\033[0m" "$1"; }
yellow() { printf "\033[33m%s\033[0m" "$1"; }

result_line() {
    local metric="$1" target="$2" actual="$3" status="$4"
    printf "  %-35s %-18s %-18s %s\n" "$metric" "$target" "$actual" "$status"
}

check_pass() {
    result_line "$1" "$2" "$3" "$(green PASS)"
    ((PASS++))
}

check_fail() {
    result_line "$1" "$2" "$3" "$(red FAIL)"
    ((FAIL++))
}

check_skip() {
    result_line "$1" "$2" "$3" "$(yellow SKIP)"
    ((SKIP++))
}

# ── Preflight ──

echo "=== term-mesh Performance Benchmark ==="
echo ""

DAEMON_PID=$(pgrep -f "term-meshd" 2>/dev/null | head -1 || true)
if [ -z "$DAEMON_PID" ]; then
    echo "ERROR: term-meshd is not running."
    echo "Start it with: cd daemon && cargo run --bin term-meshd"
    exit 1
fi

echo "Daemon PID: $DAEMON_PID"
echo "Socket:     $SOCK"
echo "HTTP:       http://localhost:$PORT"
echo ""

printf "  %-35s %-18s %-18s %s\n" "METRIC" "TARGET" "ACTUAL" "STATUS"
printf "  %-35s %-18s %-18s %s\n" "------" "------" "------" "------"

# ── 1. Daemon RSS Memory (target: <= 50 MB) ──

RSS_KB=$(ps -o rss= -p "$DAEMON_PID" 2>/dev/null | tr -d ' ')
if [ -n "$RSS_KB" ]; then
    RSS_MB=$((RSS_KB / 1024))
    if [ "$RSS_MB" -le 50 ]; then
        check_pass "Daemon RSS Memory" "<= 50 MB" "${RSS_MB} MB"
    else
        check_fail "Daemon RSS Memory" "<= 50 MB" "${RSS_MB} MB"
    fi
else
    check_skip "Daemon RSS Memory" "<= 50 MB" "N/A"
fi

# ── 2. HTTP Endpoint Latency (target: <= 200 ms) ──

for endpoint in /api/monitor /api/sessions /api/watcher /api/usage; do
    TIME_MS=$(curl -s -o /dev/null -w '%{time_total}' "http://localhost:${PORT}${endpoint}" 2>/dev/null || echo "0")
    # time_total is in seconds (float), convert to ms
    TIME_INT=$(printf "%.0f" "$(echo "$TIME_MS * 1000" | bc 2>/dev/null || echo 0)")
    if [ "$TIME_INT" -gt 0 ] && [ "$TIME_INT" -le 200 ]; then
        check_pass "HTTP ${endpoint}" "<= 200 ms" "${TIME_INT} ms"
    elif [ "$TIME_INT" -gt 200 ]; then
        check_fail "HTTP ${endpoint}" "<= 200 ms" "${TIME_INT} ms"
    else
        check_skip "HTTP ${endpoint}" "<= 200 ms" "unreachable"
    fi
done

# ── 3. Socket Latency — ping/pong (target: <= 50 ms) ──

if command -v socat &>/dev/null && [ -S "$SOCK" ]; then
    START=$(python3 -c "import time; print(int(time.time()*1000))")
    RESP=$(echo '{"id":1,"method":"ping","params":{}}' | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null || true)
    END=$(python3 -c "import time; print(int(time.time()*1000))")
    LATENCY=$((END - START))

    if echo "$RESP" | grep -q '"pong"'; then
        if [ "$LATENCY" -le 50 ]; then
            check_pass "Socket ping latency" "<= 50 ms" "${LATENCY} ms"
        else
            check_fail "Socket ping latency" "<= 50 ms" "${LATENCY} ms"
        fi
    else
        check_skip "Socket ping latency" "<= 50 ms" "no response"
    fi
else
    check_skip "Socket ping latency" "<= 50 ms" "socat/sock N/A"
fi

# ── 4. JSONL Scan Speed (target: <= 100 ms) ──

if [ -S "$SOCK" ] && command -v socat &>/dev/null; then
    START=$(python3 -c "import time; print(int(time.time()*1000))")
    RESP=$(echo '{"id":2,"method":"usage.scan","params":{}}' | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null || true)
    END=$(python3 -c "import time; print(int(time.time()*1000))")
    SCAN_MS=$((END - START))

    if echo "$RESP" | grep -q '"ok"'; then
        if [ "$SCAN_MS" -le 100 ]; then
            check_pass "JSONL scan (usage.scan)" "<= 100 ms" "${SCAN_MS} ms"
        else
            check_fail "JSONL scan (usage.scan)" "<= 100 ms" "${SCAN_MS} ms"
        fi
    else
        check_skip "JSONL scan (usage.scan)" "<= 100 ms" "no response"
    fi
else
    check_skip "JSONL scan (usage.scan)" "<= 100 ms" "socat/sock N/A"
fi

# ── 5. Worktree Create/List/Remove (target: 100% success) ──

TEMP_REPO=$(mktemp -d)
git -C "$TEMP_REPO" init -q 2>/dev/null
git -C "$TEMP_REPO" config user.email "bench@test.com"
git -C "$TEMP_REPO" config user.name "bench"
touch "$TEMP_REPO/README.md"
git -C "$TEMP_REPO" add . && git -C "$TEMP_REPO" commit -q -m "init" 2>/dev/null

if [ -S "$SOCK" ] && command -v socat &>/dev/null; then
    # Create
    CREATE_RESP=$(echo "{\"id\":3,\"method\":\"worktree.create\",\"params\":{\"repo_path\":\"$TEMP_REPO\"}}" \
        | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null || true)

    WT_NAME=$(echo "$CREATE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('name',''))" 2>/dev/null || true)

    if [ -n "$WT_NAME" ]; then
        # List
        LIST_RESP=$(echo "{\"id\":4,\"method\":\"worktree.list\",\"params\":{\"repo_path\":\"$TEMP_REPO\"}}" \
            | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null || true)
        LIST_COUNT=$(echo "$LIST_RESP" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('result',[])))" 2>/dev/null || echo "0")

        # Remove
        REMOVE_RESP=$(echo "{\"id\":5,\"method\":\"worktree.remove\",\"params\":{\"repo_path\":\"$TEMP_REPO\",\"name\":\"$WT_NAME\"}}" \
            | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null || true)

        if [ "$LIST_COUNT" -ge 1 ] && echo "$REMOVE_RESP" | grep -q '"ok"'; then
            check_pass "Worktree create/list/remove" "100%" "3/3 ops"
        else
            check_fail "Worktree create/list/remove" "100%" "partial"
        fi
    else
        check_fail "Worktree create/list/remove" "100%" "create failed"
    fi
else
    check_skip "Worktree create/list/remove" "100%" "socat/sock N/A"
fi

rm -rf "$TEMP_REPO"

# ── Summary ──

echo ""
TOTAL=$((PASS + FAIL + SKIP))
echo "=== Results: $(green "$PASS passed"), $(red "$FAIL failed"), $(yellow "$SKIP skipped") / $TOTAL total ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
