#!/bin/bash
# cleanup-ptys.sh — Diagnose PTY exhaustion and reclaim orphaned pane shells.
#
# macOS caps allocatable ptys at kern.tty.ptmx_max (511 by default). When a
# term-mesh instance dies without reaping its panes, every pane shell is
# reparented to launchd (PPID=1) and keeps holding its pty — plus, because
# pane ptys are spawned without FD_CLOEXEC, each surviving shell also inherits
# the master fds of its sibling panes. A handful of dead app instances is
# enough to pin hundreds of ptys, after which opening a new terminal crawls
# and eventually fails with `openpty failed: ENXIO`.
#
# Usage:
#   ./scripts/cleanup-ptys.sh                  # dry-run (report only)
#   ./scripts/cleanup-ptys.sh --kill           # reclaim orphans (asks to confirm)
#   ./scripts/cleanup-ptys.sh --kill --yes     # reclaim without confirmation
#   ./scripts/cleanup-ptys.sh --include-busy   # also target orphans with children
#   ./scripts/cleanup-ptys.sh --min-age 600    # only orphans older than 600s
#   ./scripts/cleanup-ptys.sh --no-fd-scan     # skip the (slower) lsof fd audit

set -euo pipefail

KILL=false
ASSUME_YES=false
INCLUDE_BUSY=false
FD_SCAN=true
MIN_AGE=3600

while [ $# -gt 0 ]; do
  case "$1" in
    --kill) KILL=true ;;
    --yes|-y) ASSUME_YES=true ;;
    --include-busy) INCLUDE_BUSY=true ;;
    --no-fd-scan) FD_SCAN=false ;;
    # Guard the arity here: with no value, `shift` below would fail under
    # `set -e` and exit 1 silently, never reaching the validation written for it.
    --min-age)
      if [ $# -lt 2 ]; then
        echo "--min-age expects seconds (integer), got no value" >&2
        exit 2
      fi
      MIN_AGE="$2"
      shift
      ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$MIN_AGE" in
  ''|*[!0-9]*) echo "--min-age expects seconds (integer), got: $MIN_AGE" >&2; exit 2 ;;
esac

# ── helpers ────────────────────────────────────────────────────────────────

# ps etime is [[DD-]HH:]MM:SS — BSD ps has no `etimes`, so convert by hand.
etime_to_seconds() {
  local e="$1" d=0 h=0 m=0 s=0
  case "$e" in *-*) d="${e%%-*}"; e="${e#*-}" ;; esac
  local IFS=:
  # shellcheck disable=SC2086
  set -- $e
  case $# in
    3) h=$1; m=$2; s=$3 ;;
    2) m=$1; s=$2 ;;
    1) s=$1 ;;
  esac
  # 10# forces base-10 — etime pads with zeros and 08/09 are invalid octal.
  echo $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

# Never kill a shell we are running underneath: walking our own parent chain
# is the only reliable guard when this script is invoked from a term-mesh pane.
SELF_CHAIN=" "
_p=$$
while [ "$_p" -gt 1 ]; do
  SELF_CHAIN="$SELF_CHAIN$_p "
  _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ' || true)
  [ -n "$_p" ] || break
done

is_self_ancestor() {
  case "$SELF_CHAIN" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# ── 1. pty capacity ────────────────────────────────────────────────────────

PTMX_MAX=$(sysctl -n kern.tty.ptmx_max 2>/dev/null || echo 0)
PTY_USED=$(find /dev -maxdepth 1 -name 'ttys*' 2>/dev/null | wc -l | tr -d ' ')

echo "=== PTY capacity ==="
printf '  kern.tty.ptmx_max : %s\n' "$PTMX_MAX"
printf '  allocated ptys    : %s\n' "$PTY_USED"
if [ "$PTMX_MAX" -gt 0 ]; then
  PCT=$(( PTY_USED * 100 / PTMX_MAX ))
  printf '  utilization       : %s%% (%s free)\n' "$PCT" "$(( PTMX_MAX - PTY_USED ))"
  if [ "$PCT" -ge 90 ]; then
    echo "  STATUS: CRITICAL — new terminals will be slow or fail with ENXIO"
  elif [ "$PCT" -ge 70 ]; then
    echo "  STATUS: WARNING — pty pressure building"
  else
    echo "  STATUS: ok"
  fi
fi
echo ""

# ── 2. orphaned pane shells ────────────────────────────────────────────────

# Login shells only, by one of three positive signals — never a bare `zsh`.
# An argv-less shell says nothing about how it was started: a LaunchAgent
# helper, a disowned background shell and a pane shell all look identical, and
# killing the first two is someone else's outage. A `zsh -c <command>` worker
# is likewise not a pane shell and must never be swept up here.
#
#   1. an explicit login flag  — `/bin/zsh -l`, `/bin/bash --login`
#   2. a dash-prefixed argv[0] — `-zsh` (how a login shell names itself)
#   3. the parenthesised form ps prints when argv is unreadable — `(zsh)`,
#      accepted ONLY when the process still holds a tty, since that is the
#      thing making it worth reclaiming and the only evidence left.
# One matcher, used twice: for the initial sweep here AND re-applied per PID
# immediately before signalling (still_orphan_shell). Selection and kill must
# never drift apart — a PID is only ever signalled by the same rule that
# selected it.
ORPHAN_MATCH_AWK='
  $2 == 1 {
    cmd = ""
    for (i = 5; i <= NF; i++) cmd = cmd (i > 5 ? " " : "") $i
    shell = "(zsh|bash|sh|fish)"
    if (cmd ~ ("^-?/?([a-z0-9_.-]+/)*" shell "[[:space:]]+(-[a-z]*l[a-z]*|--login)$") ||
        cmd ~ ("^-" shell "$") ||
        ($4 != "??" && cmd ~ ("^\\(" shell "\\)$")))
      print $1 "\t" $3 "\t" $4 "\t" cmd
  }'

# The candidate list is frozen before the confirmation prompt, and that prompt
# can sit unanswered for hours — long enough for a candidate to exit and its
# PID to be handed to an unrelated process. Ask the live process table again
# right before signalling; a PID that no longer matches has changed identity
# and must not be touched.
still_orphan_shell() {
  ps -o pid=,ppid=,etime=,tty=,command= -p "$1" 2>/dev/null \
    | awk "$ORPHAN_MATCH_AWK" | grep -q . 2>/dev/null
}

ORPHAN_ROWS=$(ps -eo pid,ppid,etime,tty,command 2>/dev/null | awk "$ORPHAN_MATCH_AWK" || true)

echo "=== Orphaned shells (PPID=1) ==="
if [ -z "$ORPHAN_ROWS" ]; then
  echo "  (none)"
  echo ""
else
  TOTAL=0; WITH_TTY=0; BUSY=0; TOO_YOUNG=0; PROTECTED=0
  CANDIDATES=""
  AGE_GROUPS=""

  while IFS=$'\t' read -r pid etime tty cmd; do
    [ -n "$pid" ] || continue
    TOTAL=$((TOTAL + 1))
    if [ "$tty" != "??" ]; then WITH_TTY=$((WITH_TTY + 1)); fi
    AGE_GROUPS="$AGE_GROUPS$etime\n"

    if is_self_ancestor "$pid"; then
      PROTECTED=$((PROTECTED + 1))
      continue
    fi

    AGE=$(etime_to_seconds "$etime")
    if [ "$AGE" -lt "$MIN_AGE" ]; then
      TOO_YOUNG=$((TOO_YOUNG + 1))
      continue
    fi

    # pgrep exits 1 when a shell has no children — expected under pipefail,
    # and wc has already emitted the 0, so only the status needs swallowing.
    KIDS=$(pgrep -P "$pid" 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "$KIDS" -gt 0 ] && ! $INCLUDE_BUSY; then
      BUSY=$((BUSY + 1))
      echo "  BUSY:  pid $pid ($tty, $etime) — $KIDS child process(es), kept"
      continue
    fi

    CANDIDATES="$CANDIDATES$pid "
  done <<< "$ORPHAN_ROWS"

  CAND_COUNT=$(echo "$CANDIDATES" | wc -w | tr -d ' ')

  printf '  total orphans     : %s (%s holding a tty)\n' "$TOTAL" "$WITH_TTY"
  printf '  reclaimable       : %s\n' "$CAND_COUNT"
  if [ "$BUSY" -gt 0 ]; then
    printf '  kept (busy)       : %s — rerun with --include-busy to force\n' "$BUSY"
  fi
  if [ "$TOO_YOUNG" -gt 0 ]; then
    printf '  kept (age < %ss)  : %s\n' "$MIN_AGE" "$TOO_YOUNG"
  fi
  if [ "$PROTECTED" -gt 0 ]; then
    printf '  kept (our own shell ancestry): %s\n' "$PROTECTED"
  fi
  echo ""

  # Orphans die in clusters — one cluster per app instance that exited without
  # reaping its panes, so identical ages tell you how many instances leaked.
  echo "  Age clusters (each ≈ one dead app instance):"
  CLUSTERS=$(printf "$AGE_GROUPS" | sort | uniq -c | sort -rn || true)
  printf '%s\n' "$CLUSTERS" | head -12 | while read -r n age; do
    printf '    %4s shells  age %s\n' "$n" "$age"
  done
  echo ""
fi

# ── 3. who else holds pty masters ──────────────────────────────────────────

if $FD_SCAN; then
  echo "=== /dev/ptmx fd holders (top 10) ==="
  PTMX_FDS=$(lsof /dev/ptmx 2>/dev/null | tail -n +2 || true)
  if [ -z "$PTMX_FDS" ]; then
    echo "  (none)"
  else
    TOTAL_FDS=$(printf '%s\n' "$PTMX_FDS" | wc -l | tr -d ' ')
    HOLDERS=$(printf '%s\n' "$PTMX_FDS" | awk '{print $2}' | sort -u | wc -l | tr -d ' ')
    printf '  %s master fds held by %s processes\n' "$TOTAL_FDS" "$HOLDERS"
    BY_PROC=$(printf '%s\n' "$PTMX_FDS" | awk '{print $1, $2}' | sort | uniq -c | sort -rn || true)
    printf '%s\n' "$BY_PROC" | head -10 | while read -r n comm pid; do
      printf '    %4s fds  %s (pid %s)\n' "$n" "$comm" "$pid"
    done
    # A pane shell should hold ~1 master. Anything higher means the pty was
    # spawned without FD_CLOEXEC and sibling panes' masters leaked into it,
    # so one surviving shell pins many ptys instead of one.
    WORST=$(printf '%s\n' "$BY_PROC" | head -1 | awk '{print $1}' || true)
    if [ "${WORST:-0}" -gt 4 ]; then
      echo "  NOTE: a single process holds ${WORST} master fds — one such process"
      echo "        pins that many ptys on its own. A staircase (74/74/72/69/...)"
      echo "        means each spawn inherited the masters opened before it: the"
      echo "        daemon's peer-surface path did exactly this until it set"
      echo "        FD_CLOEXEC on the forkpty master. Capture before killing"
      echo "        (see below) — the fd table is the only evidence of the source."
    fi
  fi
  echo ""

  echo "=== term-mesh components holding pty masters ==="
  FOUND=false
  for pat in term-meshd term-mesh-peer-relay "term-mesh DEV" "term-mesh.app"; do
    for pid in $(pgrep -f "$pat" 2>/dev/null || true); do
      n=$(lsof -p "$pid" 2>/dev/null | grep -c ptmx || true)
      printf '  %-24s pid %-7s %s master fd(s)\n' "$pat" "$pid" "${n:-0}"
      FOUND=true
    done
  done
  $FOUND || echo "  (no term-mesh processes running)"
  echo ""
fi

# ── 4. reclaim ─────────────────────────────────────────────────────────────

if ! $KILL; then
  echo "Dry run — use --kill to reclaim the orphaned shells listed above."
  exit 0
fi

CANDIDATES="${CANDIDATES:-}"
CAND_COUNT=$(echo "$CANDIDATES" | wc -w | tr -d ' ')
if [ "$CAND_COUNT" -eq 0 ]; then
  echo "Nothing to reclaim."
  exit 0
fi

if ! $ASSUME_YES; then
  printf 'Terminate %s orphaned shell(s)? [y/N] ' "$CAND_COUNT"
  read -r reply < /dev/tty || reply=""
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# Killing destroys the only evidence of who leaked the ptys — a dead process
# cannot be asked what its fd table looked like. Snapshot the heavy holders
# first so the next occurrence is diagnosable instead of guesswork.
# mktemp, not a hand-built name: /tmp is world-writable and the old path was
# predictable to the second, so a pre-planted symlink there would have made
# this `>` truncate whatever it pointed at (macOS has no protected_symlinks
# defence for sticky dirs). mktemp creates the file O_EXCL under our uid; the
# timestamp stays in the template so snapshots still sort by time.
FORENSICS=$(mktemp "/tmp/term-mesh-pty-forensics-$(date +%Y%m%d-%H%M%S)-XXXXXX") || FORENSICS=""
[ -n "$FORENSICS" ] && {
  echo "# pty forensics captured before reclaim"
  echo "# ptmx_max=$PTMX_MAX allocated=$PTY_USED candidates=$CAND_COUNT"
  echo ""
  echo "## candidate processes (pid, ppid, age, tty, argv, ptmx fd count)"
  for pid in $CANDIDATES; do
    meta=$(ps -o pid=,ppid=,etime=,tty=,command= -p "$pid" 2>/dev/null || true)
    [ -n "$meta" ] || continue
    n=$(lsof -p "$pid" 2>/dev/null | grep -c ptmx || true)
    printf '%s\tptmx_fds=%s\n' "$meta" "${n:-0}"
  done
  echo ""
  echo "## fd tables of the 5 heaviest holders"
  for pid in $CANDIDATES; do
    n=$(lsof -p "$pid" 2>/dev/null | grep -c ptmx || true)
    printf '%s %s\n' "${n:-0}" "$pid"
  done | sort -rn | head -5 | while read -r n pid; do
    echo "--- pid $pid ($n ptmx fds) ---"
    ps -o command= -p "$pid" 2>/dev/null || true
    lsof -p "$pid" 2>/dev/null | grep ptmx || true
  done
} > "$FORENSICS" 2>/dev/null || true
if [ -n "$FORENSICS" ]; then
  echo "Forensics snapshot: $FORENSICS"
else
  echo "WARNING: mktemp failed — proceeding without a forensics snapshot" >&2
fi
echo ""

echo "=== Reclaiming ==="
TERMED=0; KILLED=0; GONE=0; CHANGED=0
for pid in $CANDIDATES; do
  # Identity check at the last possible moment — see still_orphan_shell.
  if ! still_orphan_shell "$pid"; then
    CHANGED=$((CHANGED + 1))
    continue
  fi
  kill "$pid" 2>/dev/null || { GONE=$((GONE + 1)); continue; }
  TERMED=$((TERMED + 1))
done

# Give SIGTERM a moment, then escalate the stragglers in one pass rather than
# sleeping per-process (hundreds of orphans would take minutes otherwise).
sleep 2
for pid in $CANDIDATES; do
  if kill -0 "$pid" 2>/dev/null; then
    # Same identity check before the SIGKILL: a candidate that died on SIGTERM
    # and was recycled inside the 2s window must not eat a -9. A shell that
    # merely ignored SIGTERM (these do) still matches and gets escalated; a
    # zombie stops matching (tty gone) and needs no signal anyway.
    still_orphan_shell "$pid" || continue
    kill -9 "$pid" 2>/dev/null || true
    KILLED=$((KILLED + 1))
  fi
done

printf '  SIGTERM sent : %s\n' "$TERMED"
printf '  SIGKILL sent : %s\n' "$KILLED"
if [ "$GONE" -gt 0 ]; then printf '  already gone : %s\n' "$GONE"; fi
if [ "$CHANGED" -gt 0 ]; then
  printf '  skipped (identity changed since selection): %s\n' "$CHANGED"
fi
echo ""

sleep 1
PTY_AFTER=$(find /dev -maxdepth 1 -name 'ttys*' 2>/dev/null | wc -l | tr -d ' ')
echo "=== Result ==="
printf '  allocated ptys: %s → %s (reclaimed %s)\n' "$PTY_USED" "$PTY_AFTER" "$(( PTY_USED - PTY_AFTER ))"
if [ "$PTMX_MAX" -gt 0 ]; then
  printf '  utilization   : %s%% → %s%%\n' \
    "$(( PTY_USED * 100 / PTMX_MAX ))" "$(( PTY_AFTER * 100 / PTMX_MAX ))"
fi
