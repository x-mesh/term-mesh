#!/usr/bin/env bash
set -euo pipefail

# Upload term-mesh dSYM debug symbols to Sentry.
#
# Usage:
#   ./scripts/upload-dsym.sh                        # use the Release dSYM xcodebuild reports
#   ./scripts/upload-dsym.sh /path/to/term-mesh.app.dSYM
#   ./scripts/upload-dsym.sh --build                # xcodebuild Release then upload
#
# Requirements:
#   - sentry-cli installed (brew install getsentry/tools/sentry-cli)
#   - ~/.sentryclirc with [auth] token= and project .sentryclirc with [defaults]
#
# This script REFUSES to upload symbols that do not belong to the current
# checkout. Uploading the wrong dSYM is worse than uploading none: Sentry
# accepts it, every later crash resolves against stale line numbers, and
# nothing surfaces the mistake — you find out when a stack trace lies to you
# months later. Three checks enforce that, and each one exits non-zero:
#
#   1. The dSYM comes from `xcodebuild -showBuildSettings`, not a filesystem
#      search. A `find` over DerivedData picks by directory mtime, which is
#      NOT updated when a build refreshes the bundle's contents — and with
#      more than one DerivedData directory for this project (a worktree, a
#      renamed checkout) it silently selects the wrong one.
#   2. The version embedded in the built .app must equal the project's.
#   3. The dSYM's UUID must equal the app binary's. This is the only check
#      Sentry itself cares about: symbolication matches on UUID alone.

PROJECT_FILE="GhosttyTabs.xcodeproj/project.pbxproj"

die() { echo "Error: $*" >&2; exit 1; }

command -v sentry-cli >/dev/null 2>&1 \
  || die "sentry-cli not installed. Run: brew install getsentry/tools/sentry-cli"
[[ -f "$PROJECT_FILE" ]] || die "$PROJECT_FILE not found. Run from repo root."

MARKETING=$(grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
echo "Project version: $MARKETING ($BUILD)"

DSYM_PATH=""
DO_BUILD=0

case "${1:-}" in
  --build) DO_BUILD=1 ;;
  "")      ;;
  *)       DSYM_PATH="$1" ;;
esac

if [[ "$DO_BUILD" == "1" ]]; then
  echo "Building Release configuration..."
  BUILD_LOG="${TMPDIR:-/tmp}/term-mesh-release-build.log"
  # Keep the log instead of discarding output: a build that fails here used
  # to leave the previous run's dSYM in place, and the upload proceeded
  # against it. `set -e` catches a non-zero exit, but the reason has to be
  # readable or the next person repeats the guesswork.
  if ! xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh \
       -configuration Release -destination 'platform=macOS' build \
       >"$BUILD_LOG" 2>&1; then
    echo "--- last 30 lines of $BUILD_LOG ---" >&2
    tail -30 "$BUILD_LOG" >&2
    die "Release build failed. Full log: $BUILD_LOG"
  fi
fi

if [[ -z "$DSYM_PATH" ]]; then
  # Ask xcodebuild where it actually writes, rather than searching the disk.
  PRODUCTS_DIR="$(
    xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh \
      -configuration Release -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = /{print $2; exit}'
  )"
  [[ -n "$PRODUCTS_DIR" ]] || die "could not resolve BUILT_PRODUCTS_DIR from xcodebuild."
  DSYM_PATH="$PRODUCTS_DIR/term-mesh.app.dSYM"
fi

[[ -d "$DSYM_PATH" ]] \
  || die "dSYM not found at $DSYM_PATH. Build Release first (./scripts/upload-dsym.sh --build)."

APP_DIR="$(dirname "$DSYM_PATH")/term-mesh.app"
[[ -d "$APP_DIR" ]] || die "no term-mesh.app beside $DSYM_PATH — cannot verify the symbols match."

EMBEDDED_MARKETING="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
EMBEDDED_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
echo "dSYM path:       $DSYM_PATH"
echo "dSYM version:    $EMBEDDED_MARKETING ($EMBEDDED_BUILD)"

if [[ "$EMBEDDED_MARKETING" != "$MARKETING" ]]; then
  die "built app is $EMBEDDED_MARKETING but the project says $MARKETING.
       Uploading these symbols would attach the wrong version's line numbers to
       every future crash. Rebuild from this checkout: ./scripts/upload-dsym.sh --build"
fi

# UUID is what Sentry matches on, so this is the check that actually decides
# whether symbolication will work.
APP_UUID="$(dwarfdump --uuid "$APP_DIR/Contents/MacOS/term-mesh" 2>/dev/null | awk '{print $2; exit}')"
DSYM_UUID="$(dwarfdump --uuid "$DSYM_PATH" 2>/dev/null | awk '{print $2; exit}')"
[[ -n "$APP_UUID" && -n "$DSYM_UUID" ]] || die "could not read UUIDs via dwarfdump."
if [[ "$APP_UUID" != "$DSYM_UUID" ]]; then
  die "UUID mismatch — these symbols do not describe this binary.
       app:  $APP_UUID
       dSYM: $DSYM_UUID
       Rebuild from this checkout: ./scripts/upload-dsym.sh --build"
fi
echo "UUID verified:   $APP_UUID"

echo "Uploading dSYM to Sentry..."
sentry-cli debug-files upload --include-sources "$DSYM_PATH"
echo "Upload complete."
