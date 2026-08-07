#!/usr/bin/env bash
# Drive perf-sample.sh's verdicts against synthetic sample sets.
#
# The verdicts are the whole point of that script — they are what stops a run
# that cannot mean anything from being read as a result. A guard that never
# fires is indistinguishable from a guard that does not exist, and these ones
# only fire under conditions (a pointer crossing the window, agents finishing
# mid-set) that nobody can reproduce on demand against a live app. So the
# fixtures are written here instead, shaped like the `sample` output the parser
# actually reads, with the numbers that produced each verdict in the field.
#
#   ./scripts/test-perf-sample.sh
#
# Not covered: DRIFTED. It compares a live app's window/workspace/relay counts
# before and after a set, and --replay has no live app to change underneath it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERF="$HERE/perf-sample.sh"
[[ -x "$PERF" ]] || { echo "not executable: $PERF" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/perf-sample-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# A `sample` file the parser can read: 24 lines of preamble it skips, then the
# main thread's tree. Counts are the sample counts on each branch, which is what
# `peak` reads — never a line count.
write_run() {
  local dir="$1" n="$2" total="$3" idle="$4" cycle="$5" upd="$6" events="$7" bodies="$8" active="$9"
  local f="$dir/run-$n.txt"
  mkdir -p "$dir"
  : > "$f"
  for _ in $(seq 1 24); do echo "preamble" >> "$f"; done
  {
    echo "    + $total start  (in dyld) + 6992  [0x1]"
    echo "    + ! $idle mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x2]"
    echo "    + ! $events @objc NSWindow.termMesh_sendEvent(_:)  (in term_mesh) + 1  [0x3]"
    # Ahead of the cycle line on purpose: bodies are counted from there down, so
    # keeping the streaming marker above it makes `bodies` exactly what is asked
    # for here rather than that plus one.
    [[ "$active" == active ]] && echo "    + ! 3 AgentSession.apply(delta:)  (in term_mesh) + 1  [0x8]"
    echo "    + ! $cycle NSRunLoop.flushObservers()  (in SwiftUICore) + 396  [0x4]"
    echo "    + !   $upd AG::Graph::UpdateStack::update()  (in AttributeGraph) + 496  [0x5]"
    echo "    + !   12 AG::Graph::propagate_dirty(AG::AttributeID)  (in AttributeGraph) + 280  [0x6]"
    # `seq 1 0` prints "1 0" on BSD seq rather than nothing, so guard the zero
    # case instead of letting it write two lines.
    if (( bodies > 0 )); then
      for _ in $(seq 1 "$bodies"); do
        echo "    + !     1 closure #1 in SomeView.body.getter  (in term-mesh) + 1  [0x7]"
      done
    fi
  } >> "$f"
}

# `run_case <name> <expected exit> <expected substring> -- <perf-sample args...>`
run_case() {
  local name="$1" want_exit="$2" want_text="$3"; shift 4
  local out status
  out="$("$PERF" "$@" 2>&1)"; status=$?
  if [[ "$status" == "$want_exit" ]] && grep -qF -- "$want_text" <<<"$out"; then
    printf 'PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %s\n      wanted exit %s containing %q\n      got exit %s:\n%s\n' \
      "$name" "$want_exit" "$want_text" "$status" "$out"
    FAIL=$((FAIL + 1))
  fi
}

# 1. Nothing was streaming: every other number is a ratio against no work.
D="$WORK/idle"
for i in 1 2 3; do write_run "$D" "$i" 1000 900 80 60 0 0 quiet; done
run_case "idle set reports no data" 2 "Every run was IDLE" -- --replay "$D"

# 2. A steady set is the only shape that yields a number.
D="$WORK/steady"
for i in 1 2 3; do write_run "$D" "$i" 1000 500 900 750 0 0 active; done
run_case "steady set reports a median" 0 "updStack 750" -- --replay "$D"

# 3. The real set from 2026-08-07: 751 → 619 → 452 as the agents finished.
#    Measuring a second condition after this one measures the decay.
D="$WORK/decaying"
write_run "$D" 1 1000 450 903 751 0 0 active
write_run "$D" 2 1000 570 747 619 0 0 active
write_run "$D" 3 1000 650 554 452 0 0 active
run_case "winding-down set is refused" 3 "DECAYING" -- --replay "$D"

# 4. The real polluted run: the pointer crossed a split divider and put 31% of
#    the main thread under sendEvent, dragging 51 view bodies in with it.
D="$WORK/polluted"
write_run "$D" 1 1000 410 406 274 310 51 active
write_run "$D" 2 1000 820 413 357 0 1 active
write_run "$D" 3 1000 750 551 468 0 0 active
run_case "pointer-polluted run is excluded" 0 "1 run(s) marked DIRTY" -- --replay "$D"
# The survivors are 357 and 468; an even count takes the lower of the pair, so
# the polluted 274 is gone from the answer rather than dragging it down.
run_case "and the median comes from the survivors" 0 "median of 2 valid run(s): updStack 357" -- --replay "$D"

# 5. Excluding everything must not be reported as a confident zero.
D="$WORK/all-polluted"
for i in 1 2 3; do write_run "$D" "$i" 1000 500 900 750 400 20 active; done
run_case "no surviving run reports no median" 3 "No usable run survived" -- --replay "$D"

# 6. A directory this script did not create is never written to or removed.
D="$WORK/readonly"
for i in 1 2 3; do write_run "$D" "$i" 1000 500 900 750 0 0 active; done
SIG_BEFORE="$(find "$D" -type f | sort | xargs -I{} shasum {} | shasum)"
"$PERF" --replay "$D" >/dev/null 2>&1
SIG_AFTER="$(find "$D" -type f | sort | xargs -I{} shasum {} | shasum)"
if [[ "$SIG_BEFORE" == "$SIG_AFTER" ]]; then
  printf 'PASS  %s\n' "replay leaves its input untouched"
  PASS=$((PASS + 1))
else
  printf 'FAIL  %s\n' "replay modified its input directory"
  FAIL=$((FAIL + 1))
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]] || exit 1
