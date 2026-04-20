#!/usr/bin/env bash
set -euo pipefail

# Sync submodules after a git pull that changed .gitmodules URLs and/or
# submodule SHAs. Safe to run repeatedly — does nothing when already in sync.
#
# Run this on every machine AFTER pulling term-mesh if the submodule pointer
# or URL changed. Typical sign: `git status` shows ` m ghostty` after pull.
#
# Usage:
#   ./scripts/sync-submodules.sh

info() { printf "\033[0;34m[sync]\033[0m %s\n" "$1"; }
ok()   { printf "\033[0;32m[sync]\033[0m %s\n" "$1"; }
warn() { printf "\033[0;33m[sync]\033[0m %s\n" "$1"; }

if [[ ! -f .gitmodules ]]; then
  echo "Error: .gitmodules not found. Run from repo root." >&2
  exit 1
fi

info "Propagating .gitmodules URL changes to .git/config…"
git submodule sync

# Only update submodules actually declared in .gitmodules — skip phantom
# gitlink entries (e.g., historical homebrew-cmux) that have no URL.
PATHS=()
while IFS= read -r p; do
  [[ -n "$p" ]] && PATHS+=("$p")
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}')

if (( ${#PATHS[@]} == 0 )); then
  warn "No submodule paths found in .gitmodules — nothing to update."
else
  info "Checking out declared submodules at parent's pinned SHAs…"
  git submodule update --init --recursive "${PATHS[@]}"
  info "Summary:"
  git submodule status "${PATHS[@]}" | sed 's/^/  /'
fi

# Optional convenience: offer to enable auto-recursion globally on this
# machine so future `git pull` / `git checkout` update submodules
# automatically. Safe to skip; recommended if you tend to forget.
if [[ "$(git config --global submodule.recurse 2>/dev/null || echo false)" != "true" ]]; then
  warn "Tip: to auto-sync submodules on every pull/checkout on THIS machine only:"
  warn "     git config --global submodule.recurse true"
fi

ok "Submodules are in sync with HEAD."
