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
#   2. refuses to run while the session is still locked (exit 75), or when
#      the lock state cannot be read (exit 70). Unlock it in person or over
#      Screen Sharing; SSH cannot;
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
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
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

# Prints "locked" or "unlocked". The output is captured rather than piped into
# `grep -q`: it is ~94 KB, so grep stopping at the flag would SIGPIPE ioreg and,
# under pipefail, read a locked screen as unlocked.
lock_state() {
  local registry
  registry=$(ioreg -n Root -d1) || return 1
  if [[ "$registry" == *'"CGSSessionScreenIsLocked"=Yes'* ]]; then
    echo locked
  else
    echo unlocked
  fi
}

caffeinate -u -t 2
# The lock flag clears a moment after the display wakes.
for attempt in 1 2 3 4 5 6; do
  if ! state=$(lock_state); then
    echo "awake-run: could not read the session lock state from ioreg" >&2
    exit 70
  fi
  [[ "$state" == unlocked ]] && break
  if [[ $attempt -eq 6 ]]; then
    echo "awake-run: the screen is locked past its grace period; unlock it in person or over Screen Sharing, then rerun" >&2
    exit 75
  fi
  sleep 1
done

caffeinate -d -i "$@"
status=$?

if [[ $sleep_after -eq 1 ]]; then
  pmset displaysleepnow
fi
exit "$status"
