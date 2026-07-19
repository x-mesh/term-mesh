#!/usr/bin/env bash
#
# hw-sync-e2e.sh — drive the two-daemon mesh-sync hardware e2e (Phase S3).
#
# Orchestrates the dev-grade bootstrap across two real term-meshd daemons and
# proves a file present only on the peer (B) appears byte-identical on the
# initiator (A). This is the driver the piece-6 responder + bootstrap RPCs were
# built for; the recovery key is dev-managed (wiring-plan §6 D3), so this is a
# test harness, not a production flow.
#
# Assumptions:
#   * `tm-agent` on THIS host reaches A's sync daemon (override with --tm-agent).
#   * `ssh <peer-ssh> <remote-tm-agent>` reaches B's sync daemon.
#   * Both daemons are built with the piece-6 sync RPCs and run on macOS.
#   * `jq` and `openssl` are available on the driver host.
#
# Flow: register (same id both sides) -> collect each daemon's cert hash
#   (bootstrap-identity) -> generate recovery + DEK -> bootstrap-trust both
#   -> B `sync serve` -> A `sync start --peer` -> verify.
#
# Usage:
#   hw-sync-e2e.sh \
#     --peer-ssh jinwoo@jinwoo-macbook-pro-sub \
#     --peer-addr 192.168.0.42 \
#     --local-path  /Users/jinwoo/sync-test \
#     --remote-path /Users/jinwoo/sync-test \
#     [--bind-port 47820] \
#     [--project <hex64>] \
#     [--verify-file extra.txt] \
#     [--tm-agent tm-agent] \
#     [--remote-tm-agent tm-agent]

set -euo pipefail

PEER_SSH=""
PEER_ADDR=""
LOCAL_PATH=""
REMOTE_PATH=""
BIND_PORT="47820"
VERIFY_FILE=""
PROJECT_ID=""
TM_AGENT="tm-agent"
REMOTE_TM_AGENT="tm-agent"

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --peer-ssh)        PEER_SSH="$2"; shift 2 ;;
    --peer-addr)       PEER_ADDR="$2"; shift 2 ;;
    --local-path)      LOCAL_PATH="$2"; shift 2 ;;
    --remote-path)     REMOTE_PATH="$2"; shift 2 ;;
    --bind-port)       BIND_PORT="$2"; shift 2 ;;
    --project)         PROJECT_ID="$2"; shift 2 ;;
    --verify-file)     VERIFY_FILE="$2"; shift 2 ;;
    --tm-agent)        TM_AGENT="$2"; shift 2 ;;
    --remote-tm-agent) REMOTE_TM_AGENT="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$PEER_ADDR" ]    || die "--peer-addr is required (B's reachable IP; 127.0.0.1 for same-host)"
[ -n "$LOCAL_PATH" ]   || die "--local-path is required"
[ -n "$REMOTE_PATH" ]  || die "--remote-path is required"
command -v jq >/dev/null      || die "jq is required"
command -v openssl >/dev/null || die "openssl is required"

# A drives its own daemon locally; B's daemon over ssh — unless --peer-ssh is
# empty (both daemons on this host, distinguished only by socket), in which case
# B runs locally too.
a() { $TM_AGENT "$@"; }
if [ -n "$PEER_SSH" ]; then
  b() { ssh "$PEER_SSH" "$REMOTE_TM_AGENT" "$@"; }
  remote_sum() { ssh "$PEER_SSH" "shasum -a 256 '$1'" 2>/dev/null | awk '{print $1}'; }
else
  b() { $REMOTE_TM_AGENT "$@"; }
  remote_sum() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
fi

# Deterministic device ids (they also seed the dev control signing key); the
# recovery seed + DEK are fresh random per run.
# Caller-supplied when it wants to keep driving this project (see
# `run-synctest-jwserver.sh`, which hands the same id to the feature checks).
[ -n "$PROJECT_ID" ] || PROJECT_ID="$(openssl rand -hex 32)"
DEVICE_A="$(printf '41%.0s' {1..32})"   # 0x41 * 32
DEVICE_B="$(printf '42%.0s' {1..32})"   # 0x42 * 32
RECOVERY="$(openssl rand -hex 32)"
DEK_KEY_ID="$(openssl rand -hex 16)"
DEK_KEY="$(openssl rand -hex 32)"
PEER_B_ID="daemon-b"
PEER_B_ADDR="${PEER_ADDR}:${BIND_PORT}"

echo "== project $PROJECT_ID =="

# 1. Register the SAME project id on both daemons (B pins A's id).
echo "-- register --"
a project add "$LOCAL_PATH"  --id "$PROJECT_ID" >/dev/null
b project add "$REMOTE_PATH" --id "$PROJECT_ID" >/dev/null

# 2. Identity phase: each daemon's real certificate hash feeds the roster.
echo "-- bootstrap-identity --"
HASH_A="$(a sync bootstrap-identity --project "$PROJECT_ID" --device "$DEVICE_A" | jq -r .certificate_hash)"
HASH_B="$(b sync bootstrap-identity --project "$PROJECT_ID" --device "$DEVICE_B" | jq -r .certificate_hash)"
[ -n "$HASH_A" ] && [ "$HASH_A" != null ] || die "no cert hash from A"
[ -n "$HASH_B" ] && [ "$HASH_B" != null ] || die "no cert hash from B"

ROSTER="$(jq -cn \
  --arg da "$DEVICE_A" --arg ha "$HASH_A" \
  --arg db "$DEVICE_B" --arg hb "$HASH_B" \
  '[{device_id:$da,certificate_hash:$ha,epoch:1},
    {device_id:$db,certificate_hash:$hb,epoch:2}]')"

desc() { # $1=device $2=epoch $3=peers-json
  jq -cn \
    --arg pid "$PROJECT_ID" --arg rec "$RECOVERY" \
    --arg kid "$DEK_KEY_ID" --arg key "$DEK_KEY" \
    --arg dev "$1" --argjson epoch "$2" \
    --argjson roster "$ROSTER" --argjson peers "$3" \
    '{project_id:$pid, recovery:$rec, dek_key_id:$kid, dek_key:$key,
      device_id:$dev, epoch:$epoch, roster:$roster, peers:$peers}'
}

# 3. Apply phase, peer (B) first (no peers — it does not dial), then serve.
echo "-- bootstrap-trust B + serve --"
desc "$DEVICE_B" 2 '[]' | b sync bootstrap-trust --descriptor - >/dev/null
BOUND="$(b sync serve --project "$PROJECT_ID" --bind "0.0.0.0:${BIND_PORT}" | jq -r .bound_addr)"
echo "   B serving (bound $BOUND, reachable $PEER_B_ADDR)"

# 4. Apply phase, initiator (A) — address book points at B — then dial.
echo "-- bootstrap-trust A + start --"
PEERS_A="$(jq -cn --arg id "$PEER_B_ID" --arg addr "$PEER_B_ADDR" '[{peer_id:$id,addr:$addr}]')"
desc "$DEVICE_A" 1 "$PEERS_A" | a sync bootstrap-trust --descriptor - >/dev/null

# sync.start requires a 32-hex (16-byte) request id; the CLI's auto id is not hex.
OP="$(a sync start "$PROJECT_ID" --peer "$PEER_B_ID" --request-id "$(openssl rand -hex 16)" | jq -r .operation_id)"
[ -n "$OP" ] && [ "$OP" != null ] || die "sync start returned no operation id"
echo "   operation $OP"

# 5. Poll until terminal.
STATE=""
for _ in $(seq 1 60); do
  STATE="$(a sync status "$PROJECT_ID" "$OP" | jq -r .state)"
  case "$STATE" in
    succeeded|failed|cancelled|interrupted) break ;;
  esac
  sleep 1
done
echo "   final state: $STATE"
[ "$STATE" = succeeded ] || die "sync did not succeed (state=$STATE)"

# 6. Verify: a file that was only on B is now on A, byte-identical.
if [ -n "$VERIFY_FILE" ]; then
  echo "-- verify $VERIFY_FILE --"
  LOCAL_SUM="$(shasum -a 256 "$LOCAL_PATH/$VERIFY_FILE" 2>/dev/null | awk '{print $1}')"
  REMOTE_SUM="$(remote_sum "$REMOTE_PATH/$VERIFY_FILE")"
  [ -n "$LOCAL_SUM" ] || die "$VERIFY_FILE did not appear on A"
  [ "$LOCAL_SUM" = "$REMOTE_SUM" ] || die "checksum mismatch: A=$LOCAL_SUM B=$REMOTE_SUM"
  echo "   OK — $VERIFY_FILE identical on A and B ($LOCAL_SUM)"
fi

echo "== sync e2e PASSED =="
