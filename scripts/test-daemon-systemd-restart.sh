#!/usr/bin/env bash
# What a `systemctl restart` of term-meshd costs a relay client.
#
# Issue #403: teardown stopped part-way, systemd held the unit until
# TimeoutStopSec, and the relay socket was gone for 90 seconds. The daemon now
# bounds its own teardown; this measures the gap on a real host with real
# systemd, which the in-process test in
# daemon/term-meshd/tests/shutdown_restart.rs cannot.
#
# Run on the Linux peer host itself:
#
#   ./scripts/test-daemon-systemd-restart.sh --yes
#   ./scripts/test-daemon-systemd-restart.sh --yes --rounds 5 --bound 20
#   ./scripts/test-daemon-systemd-restart.sh --yes --stall agents
#
# It restarts the service, so every relay session on that host drops for the
# measured window. It refuses to run without --yes.
set -euo pipefail

ROUNDS=3
BOUND=20
STALL=
SCOPE=system
UNIT=term-meshd.service
APPROVED=0

while (($#)); do
  case "$1" in
    --yes) APPROVED=1; shift ;;
    --rounds) ROUNDS=$2; shift 2 ;;
    --bound) BOUND=$2; shift 2 ;;
    --stall) STALL=$2; shift 2 ;;
    --user) SCOPE=user; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "$APPROVED" != 1 ]]; then
  echo "This restarts ${UNIT} and drops every relay session on this host." >&2
  echo "Re-run with --yes to proceed." >&2
  exit 2
fi

if [[ "$(uname -s)" != Linux ]]; then
  echo "systemd restart measurement runs on the Linux peer host only." >&2
  exit 2
fi

systemctl_scoped() {
  if [[ "$SCOPE" == user ]]; then systemctl --user "$@"; else systemctl "$@"; fi
}
journal_scoped() {
  if [[ "$SCOPE" == user ]]; then journalctl --user "$@"; else journalctl "$@"; fi
}

PEER_SOCKET=${TERMMESH_PEER_SOCKET:-$(systemctl_scoped show "$UNIT" -p Environment --value \
  | tr ' ' '\n' | sed -n 's/^TERMMESH_PEER_SOCKET=//p' | tail -1)}
PEER_SOCKET=${PEER_SOCKET:-/run/term-mesh/tm-peer.sock}

STOP_TIMEOUT_US=$(systemctl_scoped show "$UNIT" -p TimeoutStopUSec --value)
echo "unit:        $UNIT ($SCOPE scope)"
echo "relay:       $PEER_SOCKET"
echo "stop bound:  $STOP_TIMEOUT_US"
echo "round bound: ${BOUND}s"

# The relay is back when a client's connect stops being refused. That is the
# exact signal the reporting client saw fail for 90 seconds.
relay_accepts() {
  python3 - "$PEER_SOCKET" <<'PY'
import socket, sys
try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        s.connect(sys.argv[1])
except OSError:
    sys.exit(1)
PY
}

DROPIN_DIR=
if [[ -n "$STALL" ]]; then
  if [[ "$SCOPE" == user ]]; then
    DROPIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/${UNIT}.d"
  else
    DROPIN_DIR="/etc/systemd/system/${UNIT}.d"
  fi
  mkdir -p "$DROPIN_DIR"
  printf '[Service]\nEnvironment=TERMMESH_SHUTDOWN_STALL=%s\n' "$STALL" \
    > "$DROPIN_DIR/99-shutdown-stall.conf"
  systemctl_scoped daemon-reload
  echo "stall:       $STALL (drop-in at $DROPIN_DIR)"
  # Leave no injected fault behind, whichever way this exits.
  trap 'rm -f "$DROPIN_DIR/99-shutdown-stall.conf"; systemctl_scoped daemon-reload; systemctl_scoped restart "$UNIT" || true' EXIT
  STALL_SINCE=$(date '+%Y-%m-%d %H:%M:%S')
  systemctl_scoped restart "$UNIT"
  until relay_accepts; do sleep 0.1; done
  # A release build compiles the injection out, so the drop-in above would be
  # a silent no-op and every measurement below would read as "the bound works".
  # Make that a failure instead.
  if ! journal_scoped -u "$UNIT" --since "$STALL_SINCE" --no-pager \
      | grep -q "teardown fault injection active"; then
    echo "FAIL: --stall $STALL had no effect. This daemon build injects no" >&2
    echo "      teardown fault (release builds never do). Measure without" >&2
    echo "      --stall, or install a debug build to exercise the bound." >&2
    exit 1
  fi
fi

WORST=0
FAILED=0
for ((round = 1; round <= ROUNDS; round++)); do
  SINCE=$(date '+%Y-%m-%d %H:%M:%S')
  START=$(date +%s.%N)
  systemctl_scoped restart "$UNIT"
  until relay_accepts; do sleep 0.05; done
  WINDOW=$(python3 -c "print(f'{$(date +%s.%N) - $START:.2f}')")
  echo "round $round: relay unavailable for ${WINDOW}s"
  awk -v w="$WINDOW" -v b="$BOUND" 'BEGIN { exit !(w > b) }' && {
    echo "  OVER the ${BOUND}s bound" >&2
    FAILED=1
  }
  awk -v w="$WINDOW" -v m="$WORST" 'BEGIN { exit !(w > m) }' && WORST=$WINDOW
  journal_scoped -u "$UNIT" --since "$SINCE" --no-pager \
    | grep -E "shutdown step|shutdown budget|runtime stalled|Killing" \
    | sed 's/^/  /' || true
done

echo "worst window: ${WORST}s"
if [[ "$FAILED" == 1 ]]; then
  echo "FAIL: a restart cost more than ${BOUND}s" >&2
  exit 1
fi
echo "PASS"
