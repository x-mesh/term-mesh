#!/usr/bin/env bash
# Run a command on a Mac whose display must stay on, such as a measurement or
# an E2E run on mac-sub over SSH.
#
#   scripts/awake-run.sh [--sleep-after] -- <command> [args...]
#
# A screen that sleeps or locks composites the lock screen, not the app, so a
# measurement taken then is meaningless. This script:
#   1. wakes the display. Within the lock grace period
#      (`sysadminctl -screenLock status`) that also clears a pending lock;
#   2. refuses to run while the session is still locked (exit 75). Unlock it
#      in person or over Screen Sharing; SSH cannot;
#   3. runs the command under `caffeinate -d -i`, so the display stays on only
#      while the command runs;
#   4. with --sleep-after, turns the display off when the command ends, so the
#      normal lock delay starts at once.
#
# Exits with the command's own status.
set -uo pipefail

sleep_after=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sleep-after) sleep_after=1; shift ;;
    --) shift; break ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) break ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "usage: $0 [--sleep-after] -- <command> [args...]" >&2
  exit 64
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "awake-run: macOS only" >&2
  exit 69
fi

screen_locked() {
  ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes'
}

caffeinate -u -t 2
# The lock flag clears a moment after the display wakes.
for _ in 1 2 3 4 5; do
  screen_locked || break
  sleep 1
done
if screen_locked; then
  echo "awake-run: the screen is locked past its grace period; unlock it in person or over Screen Sharing, then rerun" >&2
  exit 75
fi

caffeinate -d -i "$@"
status=$?

if [[ $sleep_after -eq 1 ]]; then
  pmset displaysleepnow
fi
exit "$status"
