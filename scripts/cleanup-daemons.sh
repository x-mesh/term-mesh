#!/bin/bash
# cleanup-daemons.sh — Find and clean orphaned term-meshd processes and stale sockets.
#
# Usage:
#   ./scripts/cleanup-daemons.sh          # dry-run (report only)
#   ./scripts/cleanup-daemons.sh --kill   # kill orphans and remove stale sockets
#   ./scripts/cleanup-daemons.sh --all    # kill ALL term-meshd processes

set -euo pipefail

KILL=false
ALL=false

for arg in "$@"; do
  case "$arg" in
    --kill) KILL=true ;;
    --all) ALL=true; KILL=true ;;
  esac
done

echo "=== Running term-meshd processes ==="
ps -eo pid,lstart,command | grep '[t]erm-meshd' || echo "(none)"
echo ""

if $ALL; then
  echo "=== Killing ALL term-meshd processes ==="
  pkill -f term-meshd 2>/dev/null && echo "killed" || echo "(none running)"
  echo ""
fi

echo "=== Daemon / peer / tunnel sockets ==="
SOCKETS=()
# Standard locations: daemon sockets, peer host sockets, app-side SSH tunnel
# sockets, and test/tagged leftovers. Active ones (with a listener) are kept.
# TMPDIR is unset in non-interactive SSH shells — resolve the real macOS
# per-user temp dir (where the app's daemon binds) instead of falling back
# to /tmp, or every daemon looks like an orphan when run remotely.
USER_TMP="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)}"
for pattern in /tmp/term-meshd*.sock \
               "$USER_TMP"/term-meshd*.sock \
               /tmp/term-mesh-peer-*.sock \
               /tmp/term-mesh-peer-*/peer.sock \
               /tmp/tm-peer-ssh-*.sock \
               /tmp/tm-peer-*/peer.sock \
               /tmp/term-mesh*.sock; do
  # shellcheck disable=SC2086
  for sock in $pattern; do
    [ -S "$sock" ] 2>/dev/null && SOCKETS+=("$sock") || true
  done
done
# Application Support contains spaces, so shell word-splitting cannot safely
# enumerate these paths. Collect them with NUL delimiters instead.
while IFS= read -r -d '' sock; do
  [ -S "$sock" ] && SOCKETS+=("$sock")
done < <(
  find "$HOME/Library/Application Support/term-mesh" \
    -maxdepth 1 -type s -name 'term-meshd*.sock' -print0 2>/dev/null
)
# De-duplicate (patterns overlap)
if [ ${#SOCKETS[@]} -gt 0 ]; then
  IFS=$'\n' read -r -d '' -a SOCKETS < <(printf '%s\n' "${SOCKETS[@]}" | sort -u && printf '\0') || true
fi

# Liveness = a real connect attempt. On macOS, `lsof <socket-file>` cannot
# see tokio (Rust) listeners — it reports live daemon sockets as having no
# process, so an lsof-based STALE verdict would delete active sockets.
socket_alive() {
  nc -U -w 1 "$1" < /dev/null > /dev/null 2>&1
}

# For live daemon RPC sockets, ask the daemon for its pid (daemon.status).
daemon_pid_via_rpc() {
  printf '{"jsonrpc":"2.0","id":1,"method":"daemon.status","params":{}}\n' \
    | nc -U -w 2 "$1" 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys
try: print(json.load(sys.stdin)["result"]["pid"])
except Exception: pass' 2>/dev/null || true
}

daemon_owner_pid_via_rpc() {
  printf '{"jsonrpc":"2.0","id":1,"method":"daemon.status","params":{}}\n' \
    | nc -U -w 2 "$1" 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys
try:
    owner=json.load(sys.stdin)["result"].get("owner_pid")
    print("" if owner is None else owner)
except Exception: pass' 2>/dev/null || true
}

# A daemon that advertises a dead GUI owner is orphaned even though its own
# listening socket still accepts connections. Older GUI builds did not expose
# owner_pid, so retain a narrow PPID=1 + app-bundle fallback for those only.
daemon_is_gui_orphan() {
  local pid="$1"
  local owner_pid="$2"
  local ppid=""
  local command=""

  if [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
    ! kill -0 "$owner_pid" 2>/dev/null
    return
  fi

  ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  command="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  [[ "$ppid" == "1" && "$command" == *".app/Contents/Resources/bin/term-meshd"* ]]
}

terminate_daemon_pid() {
  local pid="$1"
  local attempt=0
  kill "$pid" 2>/dev/null || true
  for attempt in 1 2 3; do
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "    → terminated"
      return 0
    fi
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    echo "    → SIGKILL (ignored SIGTERM)"
  else
    echo "    → terminated"
  fi
}

STALE_COUNT=0
ACTIVE_PIDS=""
if [ ${#SOCKETS[@]} -gt 0 ]; then
  for sock in "${SOCKETS[@]}"; do
    if ! socket_alive "$sock"; then
      echo "  STALE: $sock (connection refused)"
      STALE_COUNT=$((STALE_COUNT + 1))
      if $KILL; then
        rm -f "$sock"
        echo "    → removed"
      fi
    else
      PID=""
      OWNER_PID=""
      case "$sock" in
        *term-meshd*.sock)
          PID=$(daemon_pid_via_rpc "$sock")
          OWNER_PID=$(daemon_owner_pid_via_rpc "$sock")
          ;;
      esac
      if [ -n "$PID" ]; then
        if daemon_is_gui_orphan "$PID" "$OWNER_PID"; then
          echo "  ORPHAN-LISTENER: $sock (pid: $PID, dead owner: ${OWNER_PID:-legacy GUI})"
          if $KILL; then
            terminate_daemon_pid "$PID"
            rm -f "$sock"
            echo "    → socket removed"
          fi
        else
          echo "  ACTIVE: $sock (pid: $PID${OWNER_PID:+, owner: $OWNER_PID})"
          ACTIVE_PIDS="$ACTIVE_PIDS $PID"
        fi
      else
        echo "  ACTIVE: $sock"
      fi
      if $ALL; then
        [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
        rm -f "$sock"
        echo "    → killed and removed"
      fi
    fi
  done
  if [ "$STALE_COUNT" -eq 0 ]; then
    echo "  (all sockets are active)"
  fi
else
  echo "  (no sockets found)"
fi
echo ""

echo "=== Orphan daemons (not listening on any known socket) ==="
ORPHANS=0
for pid in $(pgrep -x term-meshd 2>/dev/null || true); do
  case " $ACTIVE_PIDS " in
    *" $pid "*) continue ;;
  esac
  PPID_VALUE=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  CMD=$(ps -o command= -p "$pid" 2>/dev/null || echo "?")
  if [ "$PPID_VALUE" != "1" ] && [ -n "$PPID_VALUE" ]; then
    echo "  UNMAPPED-ACTIVE: pid $pid (parent: $PPID_VALUE, kept; $CMD)"
    continue
  fi
  echo "  ORPHAN: pid $pid ($CMD)"
  ORPHANS=$((ORPHANS + 1))
  if $KILL; then
    # Pre-v0.157 builds ignore SIGTERM (FSEvents watcher bug) — escalate.
    terminate_daemon_pid "$pid"
  fi
done
[ "$ORPHANS" -eq 0 ] && echo "  (none)"
echo ""

echo "=== Tag data directories ==="
TAG_DIRS=0
for dir in /tmp/term-mesh-*/; do
  [ -d "$dir" ] 2>/dev/null || continue
  [ -L "${dir%/}" ] && continue
  # Peer socket dirs are live infrastructure, not tag leftovers — the socket
  # section above already reclaims stale sockets inside them. The same prefix
  # is shared by other live state (agent FIFOs, worktree locks, relay dirs),
  # so only directories that actually hold a build are treated as tag data.
  case "$dir" in
    */term-mesh-peer-*) continue ;;
    */term-mesh-agent-pipes/|*/term-mesh-worktree-locks/|*/term-mesh-paste/) continue ;;
  esac
  [ -d "$dir/Build" ] || continue
  AGE=$(( ( $(date +%s) - $(stat -f %m "$dir") ) / 86400 ))
  echo "  $dir (${AGE}d old)"
  TAG_DIRS=$((TAG_DIRS + 1))
  if $KILL && [ "$AGE" -gt 7 ]; then
    # A tagged app runs its binary out of this very directory, so an old mtime
    # does not mean nobody is using it.
    if pgrep -f "$dir" >/dev/null 2>&1; then
      echo "    → kept (a running process still uses it)"
      continue
    fi
    rm -rf "$dir"
    echo "    → removed (older than 7 days)"
  fi
done
[ "$TAG_DIRS" -eq 0 ] && echo "  (none)"
echo ""

echo "=== Daemon / debug log files ==="
for log in /tmp/term-meshd*.log /tmp/term-mesh-debug-*.log /tmp/term-mesh-debug.log; do
  [ -f "$log" ] 2>/dev/null || continue
  SIZE=$(du -h "$log" | cut -f1)
  if lsof "$log" >/dev/null 2>&1; then
    echo "  OPEN: $log ($SIZE) — in use, kept"
  else
    echo "  $log ($SIZE)"
    if $KILL; then
      rm -f "$log"
      echo "    → removed"
    fi
  fi
done
echo ""

if ! $KILL; then
  echo "Dry run — use --kill to clean stale sockets and old tag dirs, or --all to kill everything."
fi
