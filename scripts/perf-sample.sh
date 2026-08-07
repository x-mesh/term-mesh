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
# WHY THIS SCRIPT ARGUES WITH YOU
#
# Every number here is a ratio against a workload the script does not control,
# so a run can look perfectly usable and mean nothing. Four ways that happened
# during the work this script exists for, each now checked automatically:
#
#   IDLE       No agent was streaming. An idle app reports ~86% idle and a
#              small cycle no matter what the code does.
#   DIRTY      The pointer moved over the app mid-sample. One pass of the
#              cursor near a split divider put NSWindow.termMesh_sendEvent at
#              31% of the main thread and produced 51 view bodies that had
#              nothing to do with streaming. Keep your hands off the machine.
#   DECAYING   Agents finished during the sampling window. Across one set of
#              three runs idle went 45→57→65% and updStack 751→619→452, which
#              makes whichever condition you measured *second* look better.
#   DRIFTED    The app changed under the measurement — workspaces 3→5 and
#              relays 16→22 between two sets that were then compared as one
#              app. Only that topology is compared; RSS is printed beside it
#              but drifts a couple of MB on its own even while idle.
#
# Exit codes: 0 usable · 1 error · 2 every run IDLE · 3 conditions not stable.
# A non-zero exit means "no data", never "a bad result".
#
# COMPARING TWO CONDITIONS
#
# Do not measure A, change something, then measure B — decay alone will hand
# you a result. Interleave and label:
#
#   ./scripts/perf-sample.sh --tag t --label A-peers-expanded
#   (collapse the section)
#   ./scripts/perf-sample.sh --tag t --label B-peers-collapsed
#   (expand it again)
#   ./scripts/perf-sample.sh --tag t --label A2-peers-expanded
#
# B is real only if it sits below the line from A to A2. If A2 has already
# fallen most of the way to B, you measured the agents finishing.
#
# Usage:
#   ./scripts/perf-sample.sh                 # 3 runs of 8s against the installed app
#   ./scripts/perf-sample.sh -n 1 -d 5       # one 5s run
#   ./scripts/perf-sample.sh --tag observable    # a `reloads.sh --tag` staging app
#   ./scripts/perf-sample.sh --pid 1234      # an explicit process
#   ./scripts/perf-sample.sh --keep          # leave the raw samples in place
#   ./scripts/perf-sample.sh --label A       # name this condition in the output
#   ./scripts/perf-sample.sh --json          # machine-readable summary on stdout
#   ./scripts/perf-sample.sh --replay DIR    # re-read a kept sample set, take none
#
# --replay re-runs the verdict over raw samples captured earlier, which is how
# the guards above are tested: a recorded pointer-polluted set must come back
# DIRTY and a recorded winding-down set must come back DECAYING, with no live
# app involved. It never writes to or deletes DIR.
#
# Thresholds (override for testing): TERMMESH_PERF_EVENT_DIRTY_PCT,
# TERMMESH_PERF_DECAY_FLOOR_PCT.
set -uo pipefail

RUNS=3
DURATION=8
TAG=""
PID=""
KEEP=0
LABEL=""
JSON=0
REPLAY=""
# Share of main-thread samples under the app's swizzled NSWindow.sendEvent above
# which a run is pointer-polluted rather than streaming work. The bad run that
# motivated this sat at 31%; ordinary streaming stays near zero.
EVENT_DIRTY_PCT="${TERMMESH_PERF_EVENT_DIRTY_PCT:-10}"
# A run set is decaying when the last valid run's graph walk has fallen this far
# below the first. The set that motivated this fell to 60%.
DECAY_FLOOR_PCT="${TERMMESH_PERF_DECAY_FLOOR_PCT:-75}"
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
    --label)       LABEL="${2:-}"; shift 2 ;;
    --replay)      REPLAY="${2:-}"; shift 2 ;;
    --keep)        KEEP=1; shift ;;
    --json)        JSON=1; shift ;;
    -h|--help)     usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
done

# Raw samples are read from RAWDIR and derived files are written to OUTDIR.
# In replay mode those differ, so that a directory this script did not create
# is never written to and never reaches the `rm -rf` below.
RAWDIR="$OUTDIR"
if [[ -n "$REPLAY" ]]; then
  [[ -d "$REPLAY" ]] || { echo "replay directory not found: $REPLAY" >&2; exit 1; }
  RAWDIR="$REPLAY"
  RUNS="$(find "$RAWDIR" -maxdepth 1 -name 'run-*.txt' ! -name '*-main.txt' | wc -l | tr -d ' ')"
  (( RUNS > 0 )) || { echo "no run-N.txt samples in $REPLAY" >&2; exit 1; }
elif [[ -z "$PID" ]]; then
  if [[ -n "$TAG" ]]; then
    PATTERN="term-mesh STAGING ${TAG}.app/Contents/MacOS/term-mesh"
  else
    PATTERN="^/Applications/term-mesh.app/Contents/MacOS/term-mesh"
  fi
  PID="$(pgrep -f "$PATTERN" | head -1)"
fi

if [[ -z "$REPLAY" && -z "$PID" ]]; then
  echo "no running term-mesh found${TAG:+ for tag '$TAG'}" >&2
  exit 1
fi

mkdir -p "$OUTDIR"
# Only ever removes the directory this run created; RAWDIR may be the caller's.
cleanup() { [[ "$KEEP" == 1 ]] || rm -rf "$OUTDIR"; }
trap cleanup EXIT

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

# Conditions are what make two measurements comparable, so they are captured
# before AND after: an app that grew a window mid-set was never one condition.
#
# Only the topology is compared. RSS is reported next to it because it says a
# lot about which app you are looking at, but it moves on its own — a 2MB drift
# across eight idle seconds is normal, and comparing it made DRIFTED fire on
# every set. A guard that cries wolf is one nobody reads.
snapshot_topology() {
  if [[ -n "$REPLAY" ]]; then
    printf 'replayed from %s' "$REPLAY"
    return
  fi
  local scope relays
  scope="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"window.list"}' \
    | nc -U "$SOCKET" 2>/dev/null \
    | python3 -c "$SCOPE_PY" 2>/dev/null || echo "scope unknown")"
  relays="$(pgrep -f term-mesh-peer-relay | wc -l | tr -d ' ')"
  printf '%s · %s relays' "$scope" "$relays"
}

current_rss() {
  [[ -n "$REPLAY" ]] && return
  ps -p "$PID" -o rss= 2>/dev/null | awk '{printf " · %.0fMB", $1/1024}'
}

BEFORE="$(snapshot_topology)"
if [[ -n "$REPLAY" ]]; then
  echo "replay · $RUNS run(s) · $BEFORE${LABEL:+ · label $LABEL}"
else
  UPTIME="$(ps -p "$PID" -o etime= 2>/dev/null | tr -d ' ')"
  echo "pid $PID · up $UPTIME · $BEFORE$(current_rss)${LABEL:+ · label $LABEL}"
fi
echo

printf '%-5s %-8s %6s %5s %8s %8s %7s %6s\n' \
  run state idle evt cycle updStack dirty bodies

VALID_UPD=()
VALID_CYCLE=()
VALID_BODIES=()
ANY_ACTIVE=0
DIRTY_RUNS=0

for ((i = 1; i <= RUNS; i++)); do
  raw="$RAWDIR/run-$i.txt"
  main="$OUTDIR/run-$i-main.txt"
  if [[ -z "$REPLAY" ]]; then
    sample "$PID" "$DURATION" -f "$raw" >/dev/null 2>&1 || {
      echo "sample failed (is the process still alive?)" >&2; exit 1
    }
  fi
  [[ -f "$raw" ]] || { echo "missing sample: $raw" >&2; exit 1; }

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
  events="$(peak 'termMesh_sendEvent')"

  # App view bodies inside the update cycle. 0 is the goal.
  line="$(grep -n 'NSRunLoop.flushObservers()  (in SwiftUICore) + 396' "$main" | head -1 | cut -d: -f1)"
  bodies=0
  [[ -n "$line" ]] && bodies="$(sed -n "${line},$((line + 600))p" "$main" | grep -c '(in term-mesh)')"

  # Streaming or not. An idle app makes every other number meaningless.
  applies="$(grep -c 'AgentSession.apply' "$raw")"
  publishes="$(grep -c publishEntries "$raw")"
  state=IDLE
  (( applies > 0 || publishes > 0 )) && { state=ACTIVE; ANY_ACTIVE=1; }

  pct="$(python3 -c "print(f'{${idle:-0}/${total:-1}*100:.0f}%')" 2>/dev/null || echo '?')"
  evtpct_n="$(python3 -c "print(int(${events:-0}/${total:-1}*100))" 2>/dev/null || echo 0)"

  # Pointer traffic is not streaming work, and it drags view bodies in with it.
  if [[ "$state" == ACTIVE ]] && (( evtpct_n >= EVENT_DIRTY_PCT )); then
    state=DIRTY
    DIRTY_RUNS=$((DIRTY_RUNS + 1))
  fi

  if [[ "$state" == ACTIVE ]]; then
    VALID_UPD+=("${upd:-0}")
    VALID_CYCLE+=("${cycle:-0}")
    VALID_BODIES+=("$bodies")
  fi

  printf '%-5s %-8s %6s %4s%% %8s %8s %7s %6s\n' \
    "$i" "$state" "$pct" "$evtpct_n" "${cycle:-0}" "${upd:-0}" "${dirty:-0}" "$bodies"
done

AFTER="$(snapshot_topology)"
echo

median() {
  [[ $# -eq 0 ]] && { echo 0; return; }
  printf '%s\n' "$@" | sort -n | awk '{v[NR]=$1} END{print v[int((NR+1)/2)]}'
}

STATUS=ok
NOTES=()

if (( ANY_ACTIVE == 0 )); then
  STATUS=idle
  NOTES+=("Every run was IDLE — no agent was streaming, so these numbers say nothing about observation cost. Start an agent team, wait until answers are actually flowing, and measure again.")
fi

if [[ "$BEFORE" != "$AFTER" ]]; then
  [[ "$STATUS" == ok ]] && STATUS=drifted
  NOTES+=("DRIFTED — conditions changed during the set:")
  NOTES+=("  before: $BEFORE")
  NOTES+=("  after:  $AFTER")
  NOTES+=("These runs did not measure one app. Do not compare them with anything.")
fi

if (( ${#VALID_UPD[@]} >= 2 )); then
  FIRST="${VALID_UPD[0]}"
  LAST="${VALID_UPD[$(( ${#VALID_UPD[@]} - 1 ))]}"
  RATIO="$(python3 -c "print(int(${LAST:-0}/max(${FIRST:-1},1)*100))" 2>/dev/null || echo 100)"
  if (( RATIO < DECAY_FLOOR_PCT )); then
    [[ "$STATUS" == ok ]] && STATUS=decaying
    NOTES+=("DECAYING — updStack fell from $FIRST to $LAST (${RATIO}%) across the set.")
    NOTES+=("The workload is winding down. Whatever you measure next will look better for that reason alone; re-measure while it is steady, or interleave conditions (see --help).")
  fi
fi

if (( DIRTY_RUNS > 0 )); then
  NOTES+=("$DIRTY_RUNS run(s) marked DIRTY — the pointer was over the app. Those runs are excluded from the summary.")
fi

# Excluding every run leaves an empty median, which would otherwise be reported
# as a confident zero.
if (( ANY_ACTIVE == 1 )) && (( ${#VALID_UPD[@]} == 0 )); then
  [[ "$STATUS" == ok ]] && STATUS=unusable
  NOTES+=("No usable run survived — every streaming run was excluded. There is no median to report.")
fi

M_UPD="$(median "${VALID_UPD[@]+"${VALID_UPD[@]}"}")"
M_CYCLE="$(median "${VALID_CYCLE[@]+"${VALID_CYCLE[@]}"}")"
M_BODIES="$(median "${VALID_BODIES[@]+"${VALID_BODIES[@]}"}")"

if (( JSON == 1 )); then
  python3 - "$STATUS" "$LABEL" "${#VALID_UPD[@]}" "$M_UPD" "$M_CYCLE" "$M_BODIES" "$BEFORE" "$AFTER" <<'PY'
import json, sys
s, label, n, upd, cycle, bodies, before, after = sys.argv[1:9]
print(json.dumps({
    "status": s, "label": label, "valid_runs": int(n),
    "median": {"updStack": int(upd), "cycle": int(cycle), "bodies": int(bodies)},
    "conditions": {"before": before, "after": after},
}))
PY
else
  if (( ${#VALID_UPD[@]} > 0 )); then
    echo "median of ${#VALID_UPD[@]} valid run(s)${LABEL:+ [$LABEL]}: updStack $M_UPD · cycle $M_CYCLE · bodies $M_BODIES"
  fi
  for note in ${NOTES[@]+"${NOTES[@]}"}; do
    printf '%s\n' "$note" >&2
  done
fi

[[ "$KEEP" == 1 && -z "$REPLAY" ]] && echo "raw samples: $OUTDIR"

case "$STATUS" in
  ok)       exit 0 ;;
  idle)     exit 2 ;;
  *)        exit 3 ;;
esac
