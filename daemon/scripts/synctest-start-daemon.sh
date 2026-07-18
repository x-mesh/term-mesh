#!/usr/bin/env bash
# Start ONE isolated term-meshd sync test daemon and leave it running.
# Usage: synctest-start-daemon.sh <tag> <bin-dir>
# Reliable single-instance start (kills prior test daemons, detaches fully,
# verifies the socket is actually LISTENING via ss). Dev/e2e only.
set -uo pipefail
TAG="${1:?tag}"; BIN="${2:?bin dir}"
SOCK=/tmp/synctest-$TAG.sock
ST=/tmp/synctest-$TAG-state
KC=/tmp/synctest-$TAG-kc
HM=/tmp/synctest-$TAG-home

for p in $(pgrep -f 'target/release/term-meshd'); do kill -9 "$p" 2>/dev/null; done
sleep 1
rm -f "$SOCK" "/tmp/synctest-$TAG.log"; rm -rf "$ST" "$KC" "$HM"
mkdir -p "$ST" "$HM"; chmod 700 "$ST"

# setsid on Linux fully detaches; macOS has no setsid, so fall back to nohup +
# disown (enough there).
DETACH=""; command -v setsid >/dev/null 2>&1 && DETACH="setsid"
$DETACH env \
  HOME="$HM" \
  TERMMESH_DAEMON_UNIX_PATH="$SOCK" TERMMESH_SOCKET_MODE=allowAll \
  TERMMESH_SYNC_KEYCHAIN_DIR="$KC" TERMMESH_SYNC_STATE_DIR="$ST" \
  TERMMESH_SYNC_PROVISIONING_DB="$ST/prov.db" TERMMESH_SYNC_REGISTRY_DB="$ST/registry.db" \
  TERMMESH_SYNC_OPERATION_DB="$ST/operations.db" \
  nohup "$BIN/term-meshd" </dev/null >"/tmp/synctest-$TAG.log" 2>&1 &
disown 2>/dev/null || true

# Readiness: the "listening" log line, plus a real listener check where a tool
# exists for it (ss on Linux, lsof on macOS). The socket FILE existing is not
# enough — a dropped listener leaves a stale file that refuses connections.
has_listener() {
  if command -v ss >/dev/null 2>&1; then ss -xlp 2>/dev/null | grep -q "$SOCK"; return; fi
  if command -v lsof >/dev/null 2>&1; then lsof -U 2>/dev/null | grep -q "$SOCK"; return; fi
  [ -S "$SOCK" ]
}
for _ in $(seq 1 60); do
  if grep -q "listening on $SOCK" "/tmp/synctest-$TAG.log" 2>/dev/null && has_listener; then
    echo "daemon $TAG LISTENING on $SOCK (pid $(pgrep -f 'target/release/term-meshd' | head -1))"
    exit 0
  fi
  sleep 0.5
done
echo "daemon $TAG FAILED to listen on $SOCK"; tail -6 "/tmp/synctest-$TAG.log" 2>&1
exit 1
