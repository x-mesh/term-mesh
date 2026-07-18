#!/usr/bin/env bash
#
# hw-sync-features.sh — exercise the bidirectional sync feature set against two
# REAL daemons, on real hardware, over a real network.
#
# `hw-sync-e2e.sh` proves the bootstrap chain and one fetch. This goes further and
# checks the behaviours that only a live pair can show: both directions in one
# pass, permissions surviving the trip, a conflict being detected, listed,
# resolved and then propagated, deletes moving both ways, and the wipe guard
# refusing a mass delete. Several of these were found broken by hand exactly this
# way, so they are worth having as a script rather than a memory.
#
# It assumes both daemons are already bootstrapped against a shared project —
# run `hw-sync-e2e.sh` first and pass it the same project id and peer id.
#
# Usage:
#   hw-sync-features.sh \
#     --project <project-id-hex> \
#     --peer-id daemon-b \
#     --peer-ssh root@jwserver68 \
#     --local-path /tmp/sync-e2e-test-A \
#     --remote-path /root/sync-e2e-test-B \
#     --tm-agent "env TERMMESH_DAEMON_SOCKET=... /path/to/tm-agent" \
#     --remote-tm-agent "env TERMMESH_DAEMON_SOCKET=... /path/to/tm-agent"

set -uo pipefail

PROJECT=""
PEER_ID="daemon-b"
PEER_SSH=""
LOCAL_PATH=""
REMOTE_PATH=""
TM_AGENT="tm-agent"
REMOTE_TM_AGENT="tm-agent"

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "   ok — $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project)         PROJECT="$2"; shift 2 ;;
    --peer-id)         PEER_ID="$2"; shift 2 ;;
    --peer-ssh)        PEER_SSH="$2"; shift 2 ;;
    --local-path)      LOCAL_PATH="$2"; shift 2 ;;
    --remote-path)     REMOTE_PATH="$2"; shift 2 ;;
    --tm-agent)        TM_AGENT="$2"; shift 2 ;;
    --remote-tm-agent) REMOTE_TM_AGENT="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$PROJECT" ]     || die "--project is required"
[ -n "$LOCAL_PATH" ]  || die "--local-path is required"
[ -n "$REMOTE_PATH" ] || die "--remote-path is required"
command -v jq >/dev/null      || die "jq is required"
command -v openssl >/dev/null || die "openssl is required"

a() { $TM_AGENT "$@"; }
if [ -n "$PEER_SSH" ]; then
  remote() { ssh "$PEER_SSH" "$@"; }
else
  remote() { sh -c "$*"; }
fi

# `stat` speaks GNU on Linux and BSD on macOS; ask for the symbolic mode either
# way so one helper reads both ends of the pair.
local_mode()  { ls -ld "$1" 2>/dev/null | cut -c1-10; }
remote_mode() { remote "ls -ld '$1' 2>/dev/null | cut -c1-10"; }
local_exists()  { [ -e "$1" ]; }
remote_exists() { remote "test -e '$1'"; }

# One sync, polled to a terminal state. Sets LAST_STATE/LAST_ERROR rather than
# echoing them: a command substitution would run this in a subshell and the
# assignments would never reach the caller. The caller decides whether the state
# is the expected one — a guard trip SHOULD fail.
LAST_STATE=""
LAST_ERROR=""
sync_once() {
  local op
  op="$(a sync start "$PROJECT" --peer "$PEER_ID" --request-id "$(openssl rand -hex 16)" | jq -r .operation_id)"
  [ -n "$op" ] && [ "$op" != null ] || die "sync start returned no operation id"
  for _ in $(seq 1 90); do
    LAST_STATE="$(a sync status "$PROJECT" "$op" | jq -r .state)"
    case "$LAST_STATE" in succeeded|failed|cancelled|interrupted) break ;; esac
    sleep 1
  done
  LAST_ERROR="$(a sync status "$PROJECT" "$op" | jq -r '.error_code // ""')"
}

sync_must_succeed() {
  sync_once
  [ "$LAST_STATE" = succeeded ] || die "$1 (state=$LAST_STATE error=$LAST_ERROR)"
}

echo "== feature checks against project $PROJECT =="

# ── 1. Both directions in ONE pass, with permissions intact. ─────────────────
# Distinct modes per file: installing everything at one default would narrow a
# shared file or widen a private one, and only carrying the real mode is right in
# both directions.
echo "-- bidirectional + permissions --"
printf 'lives-on-A' > "$LOCAL_PATH/feat-a.txt";     chmod 0755 "$LOCAL_PATH/feat-a.txt"
printf 'secret'     > "$LOCAL_PATH/feat-private.txt"; chmod 0600 "$LOCAL_PATH/feat-private.txt"
remote "printf 'lives-on-B' > '$REMOTE_PATH/feat-b.txt' && chmod 0640 '$REMOTE_PATH/feat-b.txt'"
sync_must_succeed "bidirectional sync failed"

remote_exists "$REMOTE_PATH/feat-a.txt" || die "A's file never reached the peer (push)"
local_exists  "$LOCAL_PATH/feat-b.txt"  || die "the peer's file never reached A (fetch)"
ok "one sync moved a file in each direction"

[ "$(remote_mode "$REMOTE_PATH/feat-a.txt")" = "-rwxr-xr-x" ] \
  || die "pushed executable lost its mode: $(remote_mode "$REMOTE_PATH/feat-a.txt")"
[ "$(remote_mode "$REMOTE_PATH/feat-private.txt")" = "-rw-------" ] \
  || die "an owner-only file was widened by syncing: $(remote_mode "$REMOTE_PATH/feat-private.txt")"
[ "$(local_mode "$LOCAL_PATH/feat-b.txt")" = "-rw-r-----" ] \
  || die "fetched file lost the peer's mode: $(local_mode "$LOCAL_PATH/feat-b.txt")"
ok "permissions preserved in both directions (0755, 0600, 0640)"

# A chmod with no content change is a real change, and propagates.
chmod 0600 "$LOCAL_PATH/feat-b.txt"
sync_must_succeed "chmod-only sync failed"
[ "$(remote_mode "$REMOTE_PATH/feat-b.txt")" = "-rw-------" ] \
  || die "chmod did not propagate: $(remote_mode "$REMOTE_PATH/feat-b.txt")"
ok "a chmod-only change propagates"

# ── 2. Conflict: detected, not applied, listed, resolved, propagated. ────────
echo "-- conflict detect / list / resolve --"
printf 'edited-by-A' > "$LOCAL_PATH/feat-b.txt"
remote "printf 'edited-by-B' > '$REMOTE_PATH/feat-b.txt'"
sync_must_succeed "conflict sync failed"

# The whole point: a conflict blocks that path, not the run, and NEITHER side is
# overwritten.
[ "$(cat "$LOCAL_PATH/feat-b.txt")" = "edited-by-A" ] || die "A's edit was clobbered"
[ "$(remote "cat '$REMOTE_PATH/feat-b.txt'")" = "edited-by-B" ] || die "B's edit was clobbered"
ok "both edits survived the sync"

CONFLICTS="$(a conflict list "$PROJECT")"
COUNT="$(echo "$CONFLICTS" | jq '.conflicts | length')"
[ "$COUNT" = "1" ] || die "expected 1 conflict, got $COUNT: $CONFLICTS"
CID="$(echo "$CONFLICTS" | jq -r '.conflicts[0].conflict_id')"
[ "$(echo "$CONFLICTS" | jq -r '.conflicts[0].paths[0]')" = "feat-b.txt" ] \
  || die "conflict is on the wrong path"
a conflict get "$PROJECT" "$CID" >/dev/null || die "conflict get failed for $CID"
ok "conflict listed and fetchable ($CID)"

REMAINING="$(a conflict resolve "$PROJECT" "$CID" keep_local | jq -r .remaining)"
[ "$REMAINING" = "0" ] || die "conflict remained after resolve: $REMAINING"
[ "$(cat "$LOCAL_PATH/feat-b.txt")" = "edited-by-A" ] || die "resolve did not keep the local side"
ok "resolved keep_local"

# The base rule: a resolution must be PUSHED to the peer on the next sync, not
# undone by fetching the peer's version back, and not raised again.
sync_must_succeed "post-resolution sync failed"
[ "$(remote "cat '$REMOTE_PATH/feat-b.txt'")" = "edited-by-A" ] \
  || die "the resolution did not reach the peer"
[ "$(a conflict list "$PROJECT" | jq '.conflicts | length')" = "0" ] \
  || die "the conflict was raised again after resolution"
ok "resolution propagated to the peer and did not recur"

# ── 3. Deletes, both directions — including a never-transferred file. ────────
echo "-- delete propagation --"
# `feat-shared.txt` is written identically on both sides and never transferred:
# it is agreed state all the same, so deleting it must propagate rather than be
# pushed back. That resurrection was a real bug.
printf 'identical' > "$LOCAL_PATH/feat-shared.txt"
remote "printf 'identical' > '$REMOTE_PATH/feat-shared.txt'"
sync_must_succeed "sync before delete failed"

rm -f "$LOCAL_PATH/feat-a.txt"                       # transferred earlier
remote "rm -f '$REMOTE_PATH/feat-shared.txt'"        # never transferred
sync_must_succeed "delete sync failed"

remote_exists "$REMOTE_PATH/feat-a.txt" && die "A's delete did not reach the peer"
local_exists "$LOCAL_PATH/feat-shared.txt" && die "the peer's delete of a never-transferred file did not reach A"
remote_exists "$REMOTE_PATH/feat-shared.txt" && die "a never-transferred file was resurrected on the peer"
ok "deletes propagated both ways, including a never-transferred path"

# ── 4. The wipe guard. ──────────────────────────────────────────────────────
echo "-- delete guard --"
remote "cd '$REMOTE_PATH' && for i in \$(seq 1 12); do printf 'bulk-%s' \"\$i\" > guard-\$i.txt; done"
sync_must_succeed "guard seed sync failed"
BEFORE="$(ls -1 "$LOCAL_PATH" | wc -l | tr -d ' ')"
[ "$BEFORE" -ge 13 ] || die "expected the seed files on A, found $BEFORE entries"

# Remove nearly everything on the peer: that is what a partial or empty manifest
# also looks like, so it must be refused rather than mirrored.
remote "cd '$REMOTE_PATH' && rm -f guard-*.txt feat-b.txt feat-private.txt"
sync_once
[ "$LAST_STATE" = failed ] || die "the guard let a near-total delete through (state=$LAST_STATE)"
[ "$LAST_ERROR" = "delete_guard_tripped" ] \
  || die "guard tripped but reported '$LAST_ERROR' instead of delete_guard_tripped"
AFTER="$(ls -1 "$LOCAL_PATH" | wc -l | tr -d ' ')"
[ "$AFTER" = "$BEFORE" ] || die "the guard failed the run but still deleted ($BEFORE -> $AFTER)"
ok "near-total delete refused as delete_guard_tripped, tree intact"

echo "== sync feature checks PASSED =="
