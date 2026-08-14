#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/ghostty-abi.sh"

if ! ghostty_kit_is_consistent "$PROJECT_DIR"; then
    echo "error: GhosttyKit does not match the ghostty commit pinned by this checkout." >&2
    ghostty_kit_report "$PROJECT_DIR"
    echo "error: run ./scripts/setup.sh before building." >&2
    exit 1
fi

if [ "${TERMMESH_GHOSTTYKIT_CHECK_QUIET:-0}" != 1 ]; then
    sha="$(git -C "$PROJECT_DIR" rev-parse HEAD:ghostty)"
    echo "GhosttyKit verified (${sha:0:12})"
fi
