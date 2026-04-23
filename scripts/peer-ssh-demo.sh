#!/usr/bin/env bash
# peer-ssh-demo.sh — drive the peer-federation PoC over an SSH tunnel.
#
# Scenario: the host side runs `term-meshd` with TERMMESH_PEER_SOCKET set,
# SSH forwards that Unix socket to the caller, and `tm-agent peer attach`
# connects through the forwarded local socket.
#
# Works across two machines or against localhost (useful for a local smoke
# test with no second Mac).
#
# Usage:
#   # Against a remote host (set up SSH first):
#   ./scripts/peer-ssh-demo.sh user@mac-mini.local
#
#   # Against localhost (requires `ssh localhost` to work non-interactively):
#   ./scripts/peer-ssh-demo.sh localhost
#
# The script assumes the remote machine ALSO has a built `term-meshd`
# available at the same path and a matching `tm-agent` locally.
# Paths can be overridden via env: REMOTE_DAEMON, LOCAL_TM_AGENT.
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <ssh-target>" >&2
    echo "  e.g. $0 localhost" >&2
    echo "       $0 user@mac-mini.local" >&2
    exit 1
fi

SSH_TARGET="$1"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DAEMON="${REMOTE_DAEMON:-$REPO_ROOT/daemon/target/debug/term-meshd}"
LOCAL_TM_AGENT="${LOCAL_TM_AGENT:-$REPO_ROOT/daemon/target/debug/tm-agent}"

HOST_SOCK="/tmp/tm-peer-host-$$.sock"
CLIENT_SOCK="/tmp/tm-peer-client-$$.sock"
LOG="/tmp/tm-peer-ssh-demo-$$.log"

cleanup() {
    set +e
    [[ -n "${REMOTE_PID:-}" ]] && ssh "$SSH_TARGET" "kill ${REMOTE_PID} 2>/dev/null" >/dev/null 2>&1
    pkill -f "L $CLIENT_SOCK:" >/dev/null 2>&1
    rm -f "$CLIENT_SOCK"
    ssh "$SSH_TARGET" "rm -f $HOST_SOCK" >/dev/null 2>&1
}
trap cleanup EXIT

echo "==> starting term-meshd on $SSH_TARGET (socket=$HOST_SOCK)"
REMOTE_PID=$(ssh -T -q -o LogLevel=QUIET "$SSH_TARGET" "TERM_MESH_HTTP_DISABLED=1 TERMMESH_PEER_SOCKET=$HOST_SOCK nohup $REMOTE_DAEMON >$LOG 2>&1 </dev/null & echo \$!" 2>/dev/null | tail -1)
echo "    remote pid=$REMOTE_PID"

# Wait for the remote socket to appear.
for i in $(seq 1 20); do
    if ssh "$SSH_TARGET" "test -S $HOST_SOCK" 2>/dev/null; then
        break
    fi
    sleep 0.3
done
ssh "$SSH_TARGET" "test -S $HOST_SOCK" || {
    echo "ERROR: remote socket $HOST_SOCK never appeared; check $LOG on $SSH_TARGET" >&2
    exit 1
}

echo "==> establishing SSH tunnel $CLIENT_SOCK -> $SSH_TARGET:$HOST_SOCK"
ssh -f -N -T -q \
    -o LogLevel=QUIET \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new \
    -L "$CLIENT_SOCK:$HOST_SOCK" "$SSH_TARGET" >/dev/null 2>&1

for i in $(seq 1 20); do
    [[ -S "$CLIENT_SOCK" ]] && break
    sleep 0.2
done
[[ -S "$CLIENT_SOCK" ]] || {
    echo "ERROR: local forwarded socket $CLIENT_SOCK did not appear" >&2
    exit 1
}

echo "==> attaching (will stream ticks for ~4s then detach)"
(sleep 4) | "$LOCAL_TM_AGENT" peer attach "$CLIENT_SOCK"
echo "==> demo done"
