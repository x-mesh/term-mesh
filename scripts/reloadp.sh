#!/usr/bin/env bash
set -euo pipefail

xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Release -destination 'platform=macOS' build
pkill -x term-mesh || true
sleep 0.2
APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/term-mesh.app" -print0 \
  | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
  | sort -nr \
  | head -n 1 \
  | cut -d' ' -f2-
)"
if [[ -z "${APP_PATH}" ]]; then
  echo "term-mesh.app not found in DerivedData" >&2
  exit 1
fi
# Copy daemon binaries into app bundle
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$APP_PATH/Contents/Resources/bin"
mkdir -p "$BIN_DIR"
for bin in term-meshd term-mesh-run tm-agent term-mesh-peer-relay tm-agent-bridge; do
  src="$PROJECT_DIR/daemon/target/release/$bin"
  if [[ -x "$src" ]]; then
    cp "$src" "$BIN_DIR/$bin"
    chmod +x "$BIN_DIR/$bin"
  fi
done
# Re-sign AFTER copying daemon binaries into Contents/Resources/bin. The cp adds
# files the app's resource seal (from the Xcode build) doesn't cover, so the
# bundle signature becomes invalid ("a sealed resource is missing or invalid").
# `open` from a terminal still launches it, but LaunchServices — Finder,
# Spotlight, Raycast — rejects it as "damaged". Ad-hoc re-seal fixes it; the
# daemon bins are already linker-signed. Surface failures instead of swallowing.
/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$APP_PATH" \
  || echo "warning: codesign re-sign failed; Finder/Spotlight/Raycast launch may be rejected" >&2

# Install into /Applications so Launchpad / Spotlight / Raycast resolve and launch
# this dogfood build — they only index standard locations, never DerivedData.
# The brew cask normally owns this path; a dogfood build deliberately overwrites
# it. Run `brew reinstall --cask term-mesh` to restore the release build later.
INSTALL_PATH="/Applications/term-mesh.app"
rm -rf "$INSTALL_PATH"
cp -R "$APP_PATH" "$INSTALL_PATH"
# cp -R re-materializes the bundle, so re-seal in place to keep the signature valid.
/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$INSTALL_PATH" \
  || echo "warning: codesign re-sign of installed app failed; Launchpad launch may be rejected" >&2
xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true
# Point LaunchServices at THIS bundle so it stops resolving the old damaged shell.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREGISTER" -f "$INSTALL_PATH" 2>/dev/null || true

# Dev shells (including CI/Codex) often force-disable paging by exporting these.
# Don't leak that into term-mesh, otherwise `git diff` won't page even with PAGER=less.
env -u GIT_PAGER -u GH_PAGER open "$INSTALL_PATH"
osascript -e 'tell application "term-mesh" to activate' || true
