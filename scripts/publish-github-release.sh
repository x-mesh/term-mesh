#!/usr/bin/env bash
# publish-github-release.sh — create (or update) the GitHub release for a tag
# and upload the DMG built by `make dmg`.
#
# Usage:
#   ./scripts/publish-github-release.sh <version> [dmg-path]
#
# Notes:
#   - Requires `gh` authenticated against the x-mesh org.
#   - If <dmg-path> is omitted, defaults to ./term-mesh-macos-<version>.dmg
#     (the file produced by `make dmg`).
#   - Re-running for an existing release replaces the DMG asset and regenerates
#     the release notes from CHANGELOG.md.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version> [dmg-path]" >&2
  exit 1
fi

TAG="v${VERSION}"
DMG_PATH="${2:-./term-mesh-macos-${VERSION}.dmg}"
REPO="${REPO:-x-mesh/term-mesh}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "ERROR: DMG not found at $DMG_PATH" >&2
  echo "Run 'make dmg' first (produces term-mesh-macos-<version>.dmg)." >&2
  exit 1
fi

# Make sure the tag exists on origin
if ! git ls-remote --tags origin "$TAG" | grep -q "$TAG"; then
  echo "ERROR: tag $TAG not found on origin. Push it first." >&2
  exit 1
fi

# Extract the changelog section for this version (best-effort)
NOTES_FILE=$(mktemp -t term-mesh-notes.XXXXXX.md)
trap 'rm -f "$NOTES_FILE"' EXIT

awk -v ver="$VERSION" '
  $0 ~ "^## \\[" ver "\\]" { keep=1; print; next }
  keep && /^## \[/ { exit }
  keep { print }
' CHANGELOG.md >"$NOTES_FILE" || true

if [[ ! -s "$NOTES_FILE" ]]; then
  echo "Release ${VERSION}" >"$NOTES_FILE"
fi

# Create or update the release
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "==> Updating release $TAG on $REPO"
  gh release edit "$TAG" --repo "$REPO" --notes-file "$NOTES_FILE"
  gh release upload "$TAG" --repo "$REPO" --clobber "$DMG_PATH"
else
  echo "==> Creating release $TAG on $REPO"
  gh release create "$TAG" --repo "$REPO" \
    --title "term-mesh ${VERSION}" \
    --notes-file "$NOTES_FILE" \
    "$DMG_PATH"
fi

echo ""
echo "==> Release URL:"
gh release view "$TAG" --repo "$REPO" --json url --jq '.url'
