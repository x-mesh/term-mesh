#!/usr/bin/env bash
# Remove stale top-level Cargo incremental build directories.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBUG_DIR="$SCRIPT_DIR/../daemon/target/debug"
INCREMENTAL_DIR="$DEBUG_DIR/incremental"
DAYS=3
APPLY=0

usage() {
  cat <<'EOF'
Usage: cleanup-rust-incremental.sh [--apply] [--days DAYS]

Options:
  --apply       Delete stale directories (default: dry-run)
  --days DAYS   Keep directories touched within this many days (default: 3)
  -h, --help    Show this help

Examples:
  ./scripts/cleanup-rust-incremental.sh
  ./scripts/cleanup-rust-incremental.sh --apply --days 30
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --days)
      [[ $# -ge 2 ]] || { echo "--days requires a value" >&2; exit 2; }
      DAYS="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$DAYS" =~ ^[1-9][0-9]*$ ]] || { echo "--days must be a positive integer" >&2; exit 2; }

if [[ ! -d "$INCREMENTAL_DIR" ]]; then
  echo "incremental directory not found: $INCREMENTAL_DIR"
  exit 0
fi

if [[ "$APPLY" -eq 1 ]] \
  && [[ -f "$DEBUG_DIR/.cargo-lock" ]] \
  && lsof "$DEBUG_DIR/.cargo-lock" >/dev/null 2>&1; then
  echo "this Cargo target is in use; refusing to delete incremental data" >&2
  exit 1
fi

if [[ "$APPLY" -eq 1 ]]; then
  MODE=apply
else
  MODE=dry-run
fi

COUNT=0
while IFS= read -r -d '' candidate; do
  # Keep the whole unit when any nested file or directory was recently touched.
  if find "$candidate" -mtime "-$DAYS" -print -quit | grep -q .; then
    continue
  fi

  COUNT=$((COUNT + 1))
  SIZE="$(du -sh "$candidate" | awk '{print $1}')"
  echo "[$MODE] $candidate ($SIZE)"

  if [[ "$APPLY" -eq 1 ]]; then
    rm -rf -- "$candidate"
  fi
done < <(find "$INCREMENTAL_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

echo "[$MODE] matched $COUNT director$( [[ "$COUNT" -eq 1 ]] && echo y || echo ies ) older than ${DAYS} days"

if [[ "$APPLY" -eq 0 && "$COUNT" -gt 0 ]]; then
  echo "dry-run only; re-run with --apply to delete them"
fi
