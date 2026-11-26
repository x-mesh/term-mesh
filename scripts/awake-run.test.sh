#!/usr/bin/env bash
# Tests for scripts/awake-run.sh with fake ioreg, caffeinate and pmset on PATH,
# so no real display is woken, kept on or turned off.
#
#   scripts/awake-run.test.sh [path/to/awake-run.sh]
set -uo pipefail

script=${1:-"$(cd "$(dirname "$0")" && pwd)/awake-run.sh"}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fakes="$work/bin"
mkdir -p "$fakes"

# ioreg prints the lock flag near the top and then ~100 KB more, like the real
# registry, so a reader that stops early makes ioreg hit SIGPIPE. It reports
# "locked" while $work/locked-for is above 0, counting down once per call;
# -1 means locked for good, "fail" makes ioreg itself fail.
cat > "$fakes/ioreg" <<'EOF'
#!/usr/bin/env bash
state=$(cat "$AWAKE_TEST_DIR/locked-for")
[[ "$state" == fail ]] && exit 1
if [[ "$state" == -1 || "$state" -gt 0 ]]; then
  flag='"CGSSessionScreenIsLocked"=Yes,'
  [[ "$state" -gt 0 ]] && echo $((state - 1)) > "$AWAKE_TEST_DIR/locked-for"
else
  flag=''
fi
echo "+-o Root  <class IORegistryEntry>"
echo "    \"IOConsoleUsers\" = ({\"kCGSSessionOnConsoleKey\"=Yes,${flag}\"kCGSessionLoginDoneKey\"=Yes})"
filler=$(printf 'x%.0s' $(seq 1 1000))
for _ in $(seq 1 100); do echo "    \"Filler\" = \"$filler\""; done
EOF

# caffeinate -u -t N only wakes; caffeinate -d -i <command> runs the command.
cat > "$fakes/caffeinate" <<'EOF'
#!/usr/bin/env bash
echo "caffeinate $*" >> "$AWAKE_TEST_DIR/calls"
[[ "$1" == -u ]] && exit 0
shift 2
exec "$@"
EOF

cat > "$fakes/pmset" <<'EOF'
#!/usr/bin/env bash
echo "pmset $*" >> "$AWAKE_TEST_DIR/calls"
EOF

# The real `sleep` would make the locked cases take seconds.
cat > "$fakes/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fakes"/*

failures=0
run_case() {
  local name=$1 locked_for=$2 expected_status=$3 expect_ran=$4
  shift 4
  rm -f "$work/ran" "$work/calls"
  echo "$locked_for" > "$work/locked-for"
  AWAKE_TEST_DIR="$work" PATH="$fakes:$PATH" bash "$script" "$@" >/dev/null 2>&1
  local status=$? ran=no
  [[ -e "$work/ran" ]] && ran=yes
  if [[ $status -eq $expected_status && $ran == "$expect_ran" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $status (want $expected_status), command ran: $ran (want $expect_ran)"
    failures=$((failures + 1))
  fi
}

mark_ran="touch $work/ran"
run_case "unlocked: runs the command"                0  0 yes -- bash -c "$mark_ran"
run_case "unlocked: returns the command's status"    0  7 yes -- bash -c "$mark_ran; exit 7"
run_case "locked for good: refuses with 75"          -1 75 no -- bash -c "$mark_ran"
run_case "locked until the display wakes: runs"      2  0 yes -- bash -c "$mark_ran"
run_case "unreadable lock state: refuses with 70"    fail 70 no -- bash -c "$mark_ran"
run_case "no command: usage, 64"                     0  64 no

run_case "--sleep-after: runs the command"           0  0 yes --sleep-after -- bash -c "$mark_ran"
if grep -q '^pmset displaysleepnow$' "$work/calls"; then
  echo "ok   --sleep-after: turns the display off"
else
  echo "FAIL --sleep-after: pmset displaysleepnow was not called"
  failures=$((failures + 1))
fi
run_case "without --sleep-after"                     0  0 yes -- bash -c "$mark_ran"
if grep -q '^pmset' "$work/calls" 2>/dev/null; then
  echo "FAIL without --sleep-after: pmset was called"
  failures=$((failures + 1))
else
  echo "ok   without --sleep-after: leaves the display alone"
fi

if [[ $failures -gt 0 ]]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
