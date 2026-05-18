#!/usr/bin/env bash
# cleanup-stale-tasks.sh — supersede tm-agent tasks stuck in "assigned"
#
# Lists every task in the current team's board where:
#   status == "assigned"
#   age    >  STALE_SECS  (default 300)
# Age is `now - max(last_progress_at, updated_at)`; tasks an agent never
# touched (last_progress_at = null) fall back to updated_at, which equals
# created_at for fresh assignments.
#
# Default is dry-run. Pass --apply to actually call
# `tm-agent task update <id> cancelled` for each match.

set -euo pipefail

STALE_SECS="${STALE_SECS:-300}"
APPLY=0

usage() {
  cat <<'EOF'
Usage: cleanup-stale-tasks.sh [--apply] [--threshold SECONDS]

Options:
  --apply              Actually supersede matching tasks (default: dry-run)
  --threshold SECONDS  Stale-age threshold in seconds (default: 300, env: STALE_SECS)
  -h, --help           Show this help

Examples:
  cleanup-stale-tasks.sh                 # dry-run with default 300s threshold
  cleanup-stale-tasks.sh --apply         # commit supersede on stale tasks
  cleanup-stale-tasks.sh --threshold 60  # dry-run with 60s threshold
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --threshold) STALE_SECS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v tm-agent >/dev/null 2>&1 || { echo "tm-agent not found in PATH" >&2; exit 1; }
command -v jq       >/dev/null 2>&1 || { echo "jq not found in PATH" >&2; exit 1; }

NOW_EPOCH="$(date -u +%s)"

# Collect stale assigned tasks: "<id>\t<assignee>\t<age_secs>\t<title_short>"
mapfile -t STALE < <(
  tm-agent task list 2>/dev/null \
  | jq -r --argjson now "$NOW_EPOCH" --argjson stale "$STALE_SECS" '
      .result.tasks[]
      | select(.status == "assigned")
      | . as $t
      | (.last_progress_at // .updated_at) as $ts
      | (($ts | fromdateiso8601) // 0) as $tse
      | ($now - $tse) as $age
      | select($age > $stale)
      | "\(.id)\t\(.assignee // "-")\t\($age | floor)\t\((.title // "") | gsub("\t"; " ") | .[0:60])"
    '
)

COUNT="${#STALE[@]}"

if [[ "$APPLY" -eq 1 ]]; then
  MODE="apply"
else
  MODE="dry-run"
fi

echo "[$MODE] stale assigned tasks (threshold=${STALE_SECS}s, now=$(date -u -r "$NOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ)): ${COUNT}"

if [[ "$COUNT" -eq 0 ]]; then
  exit 0
fi

printf '  %-10s %-12s %-8s %s\n' "ID" "ASSIGNEE" "AGE_S" "TITLE"
for row in "${STALE[@]}"; do
  IFS=$'\t' read -r id assignee age title <<<"$row"
  printf '  %-10s %-12s %-8s %s\n' "$id" "$assignee" "$age" "$title"
done

if [[ "$APPLY" -ne 1 ]]; then
  echo
  echo "dry-run only. re-run with --apply to supersede the above."
  exit 0
fi

UPDATED=0
FAILED=0
for row in "${STALE[@]}"; do
  IFS=$'\t' read -r id _ _ _ <<<"$row"
  if tm-agent task update "$id" cancelled \
      "auto-cancelled by cleanup-stale-tasks.sh (age>${STALE_SECS}s)" \
      >/dev/null 2>&1; then
    UPDATED=$((UPDATED + 1))
  else
    FAILED=$((FAILED + 1))
    echo "  failed to supersede: $id" >&2
  fi
done

echo "[apply] cancelled ${UPDATED}/${COUNT} (failed=${FAILED})"
exit 0
