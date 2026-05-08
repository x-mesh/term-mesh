#!/bin/bash
# brew-upgrade-helper.sh — runs `brew upgrade --cask <token>` after the
# term-mesh app has fully exited, then relaunches it.
#
# Invoked by BrewSelfUpdater.triggerInstallAndRestart() as a detached
# /bin/bash subprocess immediately before NSApp.terminate. The Swift
# side does NOT wait for this script — it must finish on its own.
#
# Usage: brew-upgrade-helper.sh <brew_path> <cask_token> <app_path> <caller_pid>
#
# All output is appended to ~/Library/Logs/term-mesh-brew-upgrade.log.
# The log path is also echoed at startup so callers can find it.
#
# The 4th arg <caller_pid> is the PID of the term-mesh process that spawned
# this helper. We wait for THAT specific PID to exit (via `kill -0`) instead
# of pgrep'ing by name — the latter false-matches when a separate term-mesh
# instance (e.g. /Applications prod build during DEV verification) is running.

set -u

LOG="${HOME}/Library/Logs/term-mesh-brew-upgrade.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >>"$LOG"; }

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 <brew_path> <cask_token> <app_path> <caller_pid>" >&2
    echo "Logs are written to: $LOG" >&2
    exit 64
fi

BREW="$1"
CASK="$2"
APP="$3"
CALLER_PID="$4"

log "=================================================="
log "brew-upgrade-helper start: cask=$CASK app=$APP brew=$BREW pid=$$ caller=$CALLER_PID"

# Defensive validation: caller_pid must be numeric so `kill -0 "$CALLER_PID"`
# can't be tricked by a crafted argument.
if [[ ! "$CALLER_PID" =~ ^[0-9]+$ ]]; then
    log "ERROR: invalid caller pid (not numeric): $CALLER_PID"
    exit 64
fi

if [[ ! -x "$BREW" ]]; then
    log "ERROR: brew binary not executable: $BREW"
    exit 1
fi

# Wait up to 60s for the calling app's PID to exit. `kill -0 $PID` returns
# success while the process exists; we poll until it disappears.
log "waiting for caller pid=$CALLER_PID to exit (max 60s)…"
WAITED=0
while kill -0 "$CALLER_PID" 2>/dev/null; do
    sleep 0.5
    WAITED=$((WAITED + 1))
    if [[ $WAITED -ge 120 ]]; then
        log "WARN: caller pid=$CALLER_PID still running after 60s; proceeding anyway"
        break
    fi
done

# Settle briefly so brew can move the bundle without a "resource busy" race.
sleep 1

log "running: $BREW upgrade --cask --force $CASK"
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_COLOR=0 \
    "$BREW" upgrade --cask --force "$CASK" >>"$LOG" 2>&1
RC=$?
log "brew upgrade exit=$RC"

if [[ $RC -ne 0 ]]; then
    log "ERROR: brew upgrade failed; relaunching old build at $APP"
fi

if [[ -d "$APP" ]]; then
    log "relaunching $APP"
    /usr/bin/open "$APP" >>"$LOG" 2>&1 || log "WARN: open exited non-zero"
    # Belt-and-suspenders: explicitly activate so the relaunched window
    # comes to foreground even if another app currently has focus.
    # Pass the bundle name as an osascript argv item so embedded quotes/special
    # characters in the path can't break out of the AppleScript string.
    APP_BASENAME=$(basename "$APP" .app)
    /usr/bin/osascript \
        -e 'on run argv' \
        -e 'tell application (item 1 of argv) to activate' \
        -e 'end run' \
        -- "$APP_BASENAME" >>"$LOG" 2>&1 || log "WARN: osascript activate failed"
else
    log "WARN: app path not found: $APP — skipping relaunch"
fi

log "brew-upgrade-helper done"
exit "$RC"
