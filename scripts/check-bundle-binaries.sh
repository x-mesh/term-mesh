#!/usr/bin/env bash
# check-bundle-binaries.sh — verify that every daemon binary the app
# depends on is present (and executable) inside an .app bundle.
#
# Used as a guard from `make dmg` and `make deploy*` AFTER copying so
# silent omissions become loud build failures. Existed because of an
# incident where `term-mesh-peer-relay` was added to the workspace but
# never wired into the install/dmg targets, breaking peer relay for
# every user except the developer (who had a hardcoded dev-path fallback
# in PeerRelaySession.findRelayBinary). See git history for context.
#
# Usage: check-bundle-binaries.sh <path-to-.app>
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" ]] || [[ ! -d "$APP" ]]; then
  echo "Usage: $0 <path-to-.app>" >&2
  echo "       (got: ${APP:-<empty>})" >&2
  exit 2
fi

# Keep this list in sync with DAEMON_BINS in Makefile.
# Single source of truth for daemon binaries shipped with the app.
REQUIRED_BINS=(
  term-meshd
  term-mesh-run
  tm-agent
  term-mesh-peer-relay
)

BIN_DIR="$APP/Contents/Resources/bin"
missing=()

for b in "${REQUIRED_BINS[@]}"; do
  path="$BIN_DIR/$b"
  if [[ ! -f "$path" ]]; then
    missing+=("$b (not found)")
    continue
  fi
  if [[ ! -x "$path" ]]; then
    missing+=("$b (not executable)")
    continue
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "ERROR: bundle is missing required daemon binaries in $BIN_DIR:" >&2
  for m in "${missing[@]}"; do
    echo "  - $m" >&2
  done
  echo "" >&2
  echo "Update DAEMON_BINS in Makefile and REQUIRED_BINS in this script" >&2
  echo "if you intentionally removed one." >&2
  exit 1
fi

echo "==> Bundle binaries OK (${#REQUIRED_BINS[@]} verified)"
