#!/usr/bin/env bash
# Sample the running app's main thread and report the SwiftUI observation cost.
#
# What this measures, and why these symbols:
#
#   AG::Graph::UpdateStack::update   AttributeGraph *walking* the view graph.
#   AG::Graph::propagate_dirty       How far an invalidation spreads.
#   NSRunLoop.flushObservers         The SwiftUI update cycle as a whole.
#   term-mesh bodies in the cycle    App views actually being re-evaluated.
#
# The last one is the sharpest signal. When invalidation is scoped correctly, a
# streamed delta re-evaluates nothing in the app — the count is 0 — and what is
# left inside the cycle is AttributeGraph traversal, which is a function of how
# large the graph is rather than of what changed.
#
# Reference points, ten agents streaming, two windows, Review Board open
# (before = v0.175.1, after = @Observable migration, PR #180 + #182):
#
#                               before   after
#   UpdateStack::update           1017   ~400
#   SwiftUI update cycle          1242   ~470
#   main-thread idle               46%    74%
#   propagate_dirty                 40   6-13
#   app view bodies in cycle       many    0-2
#
# READ THIS BEFORE TRUSTING A NUMBER
#
#   1. Agents must be streaming. An idle app reports ~86% idle and a small
#      cycle no matter what the code does; four separate measurements were
#      thrown away during this work for exactly that reason. The script prints
#      an ACTIVE/IDLE verdict per run — treat IDLE runs as no data, not as a
#      good result.
#   2. Control the conditions. Window count, workspace count and peer count all
#      move these numbers. Compare like with like, or compare nothing.
#   3. Read the branch's sample count, never `grep -c`. A line count reflects
#      recursion depth, not cost.
#
# Usage:
#   ./scripts/perf-sample.sh                 # 3 runs of 8s against the installed app
#   ./scripts/perf-sample.sh -n 1 -d 5       # one 5s run
#   ./scripts/perf-sample.sh --tag observable    # a `reloads.sh --tag` staging app
#   ./scripts/perf-sample.sh --pid 1234      # an explicit process
#   ./scripts/perf-sample.sh --keep          # leave the raw samples in place
set -uo pipefail

RUNS=3
DURATION=8
TAG=""
PID=""
KEEP=0
OUTDIR="${TMPDIR:-/tmp}/term-mesh-perf-sample.$$"


usage() {
  sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--runs)     RUNS="${2:-}"; shift 2 ;;
    -d|--duration) DURATION="${2:-}"; shift 2 ;;
    --tag)         TAG="${2:-}"; shift 2 ;;
    --pid)         PID="${2:-}"; shift 2 ;;
    --keep)        KEEP=1; shift ;;
    -h|--help)     usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "$PID" ]]; then
  if [[ -n "$TAG" ]]; then
    PATTERN="term-mesh STAGING ${TAG}.app/Contents/MacOS/term-mesh"
  else
    PATTERN="^/Applications/term-mesh.app/Contents/MacOS/term-mesh"
  fi
  PID="$(pgrep -f "$PATTERN" | head -1)"
fi

if [[ -z "$PID" ]]; then
  echo "no running term-mesh found${TAG:+ for tag '$TAG'}" >&2
  exit 1
fi

mkdir -p "$OUTDIR"
cleanup() { [[ "$KEEP" == 1 ]] || rm -rf "$OUTDIR"; }
trap cleanup EXIT

# Conditions first — these are what make two measurements comparable.
UPTIME="$(ps -p "$PID" -o etime= 2>/dev/null | tr -d ' ')"
RSS="$(ps -p "$PID" -o rss= 2>/dev/null | awk '{printf "%.0fMB", $1/1024}')"
# Sockets live in /tmp, not $TMPDIR — on macOS the latter is a per-user
# directory under /var/folders and looking there finds nothing.
SOCKET="/tmp/term-mesh.sock"
[[ -n "$TAG" ]] && SOCKET="/tmp/term-mesh-staging-${TAG}.sock"
[[ -S "$SOCKET" ]] || SOCKET="/tmp/term-mesh.sock"
read -r -d '' SCOPE_PY <<'PY' || true
import sys, json
try:
    w = json.load(sys.stdin)["result"]["windows"]
    n = sum(x["workspace_count"] for x in w)
    print(str(len(w)) + " windows / " + str(n) + " workspaces")
except Exception:
    print("scope unknown")
PY
SCOPE="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"window.list"}' \
  | nc -U "$SOCKET" 2>/dev/null \
  | python3 -c "$SCOPE_PY" 2>/dev/null || echo "scope unknown")"

echo "pid $PID · up $UPTIME · $RSS · $SCOPE · $(pgrep -f term-mesh-peer-relay | wc -l | tr -d ' ') relays"
echo

printf '%-5s %-7s %6s %8s %8s %7s %6s\n' \
  run state idle cycle updStack dirty bodies

for ((i = 1; i <= RUNS; i++)); do
  raw="$OUTDIR/run-$i.txt"
  main="$OUTDIR/run-$i-main.txt"
  sample "$PID" "$DURATION" -f "$raw" >/dev/null 2>&1 || {
    echo "sample failed (is the process still alive?)" >&2; exit 1
  }

  # The main thread's tree only — everything else is worker threads parked in
  # kevent, which drowns out the signal.
  awk 'NR>=25 && /^ +[0-9]+ Thread_/ && NR>30 {exit} NR>=25 {print}' "$raw" > "$main"

  # A frame's cost is the sample count on its branch, not how many lines it
  # spans: a recursive path repeats the same symbol at every depth.
  peak() {
    grep -- "$1" "$main" 2>/dev/null \
      | sed -E 's/^[ +!:|]+//' | awk '{print $1}' | sort -rn | head -1
  }

  total="$(head -1 "$main" | sed -E 's/^[ +!:|]+//' | awk '{print $1}')"
  idle="$(peak 'mach_msg2_trap')"
  cycle="$(peak 'NSRunLoop.flushObservers')"
  upd="$(peak 'AG::Graph::UpdateStack::update')"
  dirty="$(peak 'AG::Graph::propagate_dirty')"

  # App view bodies inside the update cycle. 0 is the goal.
  line="$(grep -n 'NSRunLoop.flushObservers()  (in SwiftUICore) + 396' "$main" | head -1 | cut -d: -f1)"
  bodies=0
  [[ -n "$line" ]] && bodies="$(sed -n "${line},$((line + 600))p" "$main" | grep -c '(in term-mesh)')"

  # Streaming or not. An idle app makes every other number meaningless.
  applies="$(grep -c 'AgentSession.apply' "$raw")"
  publishes="$(grep -c publishEntries "$raw")"
  state=IDLE
  (( applies > 0 || publishes > 0 )) && state=ACTIVE

  pct="$(python3 -c "print(f'{${idle:-0}/${total:-1}*100:.0f}%')" 2>/dev/null || echo '?')"
  printf '%-5s %-7s %6s %8s %8s %7s %6s\n' \
    "$i" "$state" "$pct" "${cycle:-0}" "${upd:-0}" "${dirty:-0}" "$bodies"
done

echo
if ! grep -l 'AgentSession.apply' "$OUTDIR"/run-*.txt >/dev/null 2>&1 \
   && ! grep -l publishEntries "$OUTDIR"/run-*.txt >/dev/null 2>&1; then
  cat >&2 <<'WARN'
Every run was IDLE — no agent was streaming, so these numbers say nothing about
observation cost. Start an agent team, wait until answers are actually flowing,
and measure again.
WARN
  exit 2
fi

[[ "$KEEP" == 1 ]] && echo "raw samples: $OUTDIR"
exit 0
