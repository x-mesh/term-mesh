#!/usr/bin/env bash
# Run the two-daemon sync e2e on a single Linux host (jwserver68): two isolated
# term-meshd daemons on loopback, driven by hw-sync-e2e.sh. Dev/e2e only.
set -uo pipefail

ROOT=/root/term-mesh-synctest
BIN=$ROOT/daemon/target/release
DRIVER=$ROOT/daemon/scripts/hw-sync-e2e.sh
PORT=47820

start_daemon() { # $1=tag
  local tag=$1
  local sock=/tmp/synctest-$tag.sock
  local st=/tmp/synctest-$tag-state
  local kc=/tmp/synctest-$tag-kc
  # SecureSqlite (registry, operations db) requires the parent dir to be exactly
  # 0700 and owned by the daemon uid — create it that way, not mkdir's umask default.
  rm -f "$sock"; rm -rf "$st" "$kc"; mkdir -p "$st"; chmod 700 "$st"
  env TERMMESH_DAEMON_UNIX_PATH="$sock" TERMMESH_SOCKET_MODE=allowAll \
      TERMMESH_SYNC_KEYCHAIN_DIR="$kc" TERMMESH_SYNC_STATE_DIR="$st" \
      TERMMESH_SYNC_PROVISIONING_DB="$st/prov.db" TERMMESH_SYNC_REGISTRY_DB="$st/registry.db" \
      TERMMESH_SYNC_OPERATION_DB="$st/operations.db" \
      nohup "$BIN/term-meshd" < /dev/null > "/tmp/synctest-$tag.log" 2>&1 &
  disown
  for _ in $(seq 1 60); do
    grep -q "listening on $sock" "/tmp/synctest-$tag.log" 2>/dev/null && { echo "daemon $tag bound $sock"; return 0; }
    sleep 0.5
  done
  echo "daemon $tag FAILED to bind $sock; log tail:"; tail -5 "/tmp/synctest-$tag.log"; return 1
}

cleanup() {
  for p in $(pgrep -f 'target/release/term-meshd'); do kill -9 "$p" 2>/dev/null; done
  rm -f /tmp/synctest-A.sock /tmp/synctest-B.sock
}
trap cleanup EXIT

# Fresh start
for p in $(pgrep -f 'target/release/term-meshd'); do kill -9 "$p" 2>/dev/null; done
sleep 1

start_daemon A || exit 1
start_daemon B || exit 1

echo "=== running driver ==="
bash "$DRIVER" \
  --peer-ssh "" \
  --peer-addr 127.0.0.1 \
  --local-path /root/sync-e2e-test-A \
  --remote-path /root/sync-e2e-test-B \
  --verify-file extra.txt \
  --bind-port "$PORT" \
  --tm-agent "env TERMMESH_DAEMON_SOCKET=/tmp/synctest-A.sock $BIN/tm-agent" \
  --remote-tm-agent "env TERMMESH_DAEMON_SOCKET=/tmp/synctest-B.sock $BIN/tm-agent"
rc=$?
echo "=== driver exit $rc ==="
exit $rc
