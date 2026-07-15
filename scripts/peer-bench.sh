#!/usr/bin/env bash
# peer-bench.sh — measure the SSH tunnel's contribution to peer-relay
# latency/throughput, to decide the P8 transport question (is Native TCP
# on LAN worth it?) from numbers instead of estimates.
#
# See docs/peer-p8-measurement.md for the pre-registered decision rule.
#
# It runs `tm-agent peer bench` against the SAME term-meshd twice:
#   B (direct) — the daemon's real TERMMESH_PEER_SOCKET (no SSH).
#   A (ssh)    — a `ssh -L`-forwarded copy of that socket.
# The A−B delta isolates the SSH hop's per-op cost (framing/crypto/hop),
# which is exactly what Native TCP would remove on a real LAN. On a real
# LAN both A and Native TCP pay the same network RTT, so this loopback
# delta is the cleanest isolation of what P8 actually buys.
#
# Usage:
#   ./scripts/peer-bench.sh                 # local daemon, direct vs ssh localhost
#   ./scripts/peer-bench.sh user@host       # local daemon, direct vs ssh <host>
#                                           #   (ssh forwards back to this box's socket)
# Env overrides:
#   MODE=all|rtt|wire|throughput   (default all)
#   ITERS=<n>                      (default 30)
#   TM_AGENT=<path>  TERM_MESHD=<path>
set -euo pipefail

SSH_TARGET="${1:-localhost}"
MODE="${MODE:-all}"
ITERS="${ITERS:-30}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TM_AGENT="${TM_AGENT:-$REPO_ROOT/daemon/target/release/tm-agent}"
TERM_MESHD="${TERM_MESHD:-$REPO_ROOT/daemon/target/release/term-meshd}"

HOST_SOCK="/tmp/tm-peer-bench-host-$$.sock"
CLIENT_SOCK="/tmp/tm-peer-bench-client-$$.sock"
DLOG="/tmp/tm-peer-bench-daemon-$$.log"
DIRECT_JSON="/tmp/tm-peer-bench-direct-$$.json"
SSH_JSON="/tmp/tm-peer-bench-ssh-$$.json"

DAEMON_PID=""
cleanup() {
    set +e
    [[ -n "$DAEMON_PID" ]] && kill "$DAEMON_PID" 2>/dev/null
    pkill -f "L $CLIENT_SOCK:" >/dev/null 2>&1
    rm -f "$HOST_SOCK" "$CLIENT_SOCK" "$DIRECT_JSON" "$SSH_JSON"
}
trap cleanup EXIT

for bin in "$TM_AGENT" "$TERM_MESHD"; do
    [[ -x "$bin" ]] || { echo "ERROR: missing $bin (run: cd daemon && cargo build --release)" >&2; exit 1; }
done

echo "==> starting local term-meshd (socket=$HOST_SOCK)"
TERM_MESH_HTTP_DISABLED=1 TERMMESH_PEER_SOCKET="$HOST_SOCK" \
    "$TERM_MESHD" >"$DLOG" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 20); do [[ -S "$HOST_SOCK" ]] && break; sleep 0.3; done
[[ -S "$HOST_SOCK" ]] || { echo "ERROR: daemon socket never appeared; see $DLOG" >&2; exit 1; }

echo "==> [B] direct (no SSH)"
"$TM_AGENT" peer bench "$HOST_SOCK" --mode "$MODE" --iterations "$ITERS" --json >"$DIRECT_JSON"

echo "==> establishing SSH tunnel $CLIENT_SOCK -> $SSH_TARGET:$HOST_SOCK"
ssh -f -N -T -q \
    -o LogLevel=QUIET \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new \
    -L "$CLIENT_SOCK:$HOST_SOCK" "$SSH_TARGET" >/dev/null 2>&1
for _ in $(seq 1 20); do [[ -S "$CLIENT_SOCK" ]] && break; sleep 0.2; done
[[ -S "$CLIENT_SOCK" ]] || { echo "ERROR: forwarded socket $CLIENT_SOCK did not appear" >&2; exit 1; }

echo "==> [A] ssh ($SSH_TARGET)"
"$TM_AGENT" peer bench "$CLIENT_SOCK" --mode "$MODE" --iterations "$ITERS" --json >"$SSH_JSON"

echo
python3 - "$DIRECT_JSON" "$SSH_JSON" "$SSH_TARGET" <<'PY'
import json, sys
direct = json.load(open(sys.argv[1]))
ssh = json.load(open(sys.argv[2]))
target = sys.argv[3]

def row(label, key, field, unit, scale=1.0):
    d = direct.get(key); s = ssh.get(key)
    if not d or not s: return
    dv = d[field] * scale; sv = s[field] * scale
    delta = sv - dv
    print(f"  {label:<16} {dv:9.3f}   {sv:9.3f}   {delta:+9.3f} {unit}")

print(f"{'metric':<18}{'B direct':>10} {'A ssh':>11} {'A-B delta':>12}")
print("  " + "-"*54)
row("wire p50",      "wire_ms", "p50_ms", "ms")
row("wire p99",      "wire_ms", "p99_ms", "ms")
row("rtt(echo) p50", "rtt_ms",  "p50_ms", "ms")
row("rtt(echo) p95", "rtt_ms",  "p95_ms", "ms")
row("rtt(echo) p99", "rtt_ms",  "p99_ms", "ms")
row("rtt(echo) max", "rtt_ms",  "max_ms", "ms")
tp_d = direct.get("throughput"); tp_s = ssh.get("throughput")
if tp_d and tp_s:
    print(f"  {'throughput':<16} {tp_d['mb_per_s']:9.2f}   {tp_s['mb_per_s']:9.2f}   "
          f"{tp_s['mb_per_s']-tp_d['mb_per_s']:+9.2f} MB/s")
print()
# Pre-registered rule (docs/peer-p8-measurement.md), applied to rtt(echo) p50.
if direct.get("rtt_ms") and ssh.get("rtt_ms"):
    delta = ssh["rtt_ms"]["p50_ms"] - direct["rtt_ms"]["p50_ms"]
    verdict = ("REJECT P8-LAN (SSH overhead negligible)" if delta < 2.0
               else "PROCEED (auth/pairing first, then Native TCP)" if delta > 10.0
               else "RE-EVALUATE with secondary metrics (2-10ms band)")
    print(f"  input->echo SSH overhead (p50): {delta:+.3f} ms  =>  {verdict}")
print(f"  (target={target}; loopback isolates the SSH hop, real LAN adds equal network RTT to both)")
PY
echo "==> done"
