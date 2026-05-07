#!/bin/bash
# brew-upgrade-helper.sh — runs `brew upgrade --cask <token>` after the
# term-mesh app has fully exited, then relaunches it.
#
# Invoked by BrewSelfUpdater.triggerInstallAndRestart() as a detached
# /bin/bash subprocess immediately before NSApp.terminate. The Swift
# side does NOT wait for this script — it must finish on its own.
#
# Usage: brew-upgrade-helper.sh <brew_path> <cask_token> <app_path>
#
# All output is appended to ~/Library/Logs/term-mesh-brew-upgrade.log.
# The log path is also echoed at startup so callers can find it.

set -u

LOG="${HOME}/Library/Logs/term-mesh-brew-upgrade.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >>"$LOG"; }

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <brew_path> <cask_token> <app_path>" >&2
    echo "Logs are written to: $LOG" >&2
    exit 64
fi

BREW="$1"
CASK="$2"
APP="$3"

log "=================================================="
log "brew-upgrade-helper start: cask=$CASK app=$APP brew=$BREW pid=$$"

if [[ ! -x "$BREW" ]]; then
    log "ERROR: brew binary not executable: $BREW"
    exit 1
fi

# Wait up to 60s for term-mesh to exit. Match both production and tagged-debug
# binaries so the helper works in any DEV build that opted in (we still gate
# in Swift by /Applications path).
log "waiting for term-mesh processes to exit (max 60s)…"
for _ in $(seq 1 120); do
    if ! pgrep -x 'term-mesh' >/dev/null 2>&1 \
       && ! pgrep -x 'term-mesh DEV' >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

if pgrep -x 'term-mesh' >/dev/null 2>&1 || pgrep -x 'term-mesh DEV' >/dev/null 2>&1; then
    log "WARN: term-mesh still running after 60s; proceeding with --force anyway"
fi

# Settle the filesystem briefly to give brew a clean shot at moving the bundle.
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
else
    log "WARN: app path not found: $APP — skipping relaunch"
fi

log "brew-upgrade-helper done"
exit "$RC"
