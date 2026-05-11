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
for bin in term-meshd term-mesh-run tm-agent term-mesh-peer-relay term-meshd-tmux-relay; do
  src="$PROJECT_DIR/daemon/target/release/$bin"
  if [[ -x "$src" ]]; then
    cp "$src" "$BIN_DIR/$bin"
    chmod +x "$BIN_DIR/$bin"
  fi
done
# Dev shells (including CI/Codex) often force-disable paging by exporting these.
# Don't leak that into term-mesh, otherwise `git diff` won't page even with PAGER=less.
env -u GIT_PAGER -u GH_PAGER open "$APP_PATH"
osascript -e 'tell application "term-mesh" to activate' || true
