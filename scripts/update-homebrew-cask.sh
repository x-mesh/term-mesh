#!/usr/bin/env bash
# update-homebrew-cask.sh — update x-mesh/homebrew-tap Casks/term-mesh.rb
#
# Usage:
#   ./scripts/update-homebrew-cask.sh <version> <dmg-path-or-url>
#
# Examples:
#   ./scripts/update-homebrew-cask.sh 0.98.0 ./term-mesh-macos-0.98.0.dmg
#   ./scripts/update-homebrew-cask.sh 0.98.0 \
#     https://github.com/x-mesh/term-mesh/releases/download/v0.98.0/term-mesh-macos-0.98.0.dmg
#
# Environment:
#   TAP_REPO       default: x-mesh/homebrew-tap
#   TAP_DIR        default: $HOME/.cache/term-mesh/homebrew-tap (clone target)
#   DRY_RUN        if set, skip git push
set -euo pipefail

VERSION="${1:-}"
DMG_SRC="${2:-}"

if [[ -z "$VERSION" || -z "$DMG_SRC" ]]; then
  echo "Usage: $0 <version> <dmg-path-or-url>" >&2
  exit 1
fi

TAP_REPO="${TAP_REPO:-x-mesh/homebrew-tap}"
TAP_DIR="${TAP_DIR:-$HOME/.cache/term-mesh/homebrew-tap}"

# Resolve DMG to a local file and compute sha256
if [[ "$DMG_SRC" =~ ^https?:// ]]; then
  TMP_DMG=$(mktemp -t term-mesh-dmg.XXXXXX.dmg)
  trap 'rm -f "$TMP_DMG"' EXIT
  echo "==> Downloading DMG: $DMG_SRC"
  curl -fL --progress-bar -o "$TMP_DMG" "$DMG_SRC"
  DMG_PATH="$TMP_DMG"
else
  DMG_PATH="$DMG_SRC"
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "ERROR: DMG not found at $DMG_PATH" >&2
  exit 1
fi

SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "==> version: $VERSION"
echo "==> sha256:  $SHA256"

# Ensure tap clone
mkdir -p "$(dirname "$TAP_DIR")"
if [[ ! -d "$TAP_DIR/.git" ]]; then
  echo "==> Cloning $TAP_REPO -> $TAP_DIR"
  git clone "git@github.com:${TAP_REPO}.git" "$TAP_DIR"
else
  echo "==> Refreshing $TAP_DIR"
  git -C "$TAP_DIR" fetch origin
  git -C "$TAP_DIR" checkout main
  git -C "$TAP_DIR" reset --hard origin/main
fi

CASK_DIR="$TAP_DIR/Casks"
CASK_FILE="$CASK_DIR/term-mesh.rb"
mkdir -p "$CASK_DIR"

cat >"$CASK_FILE" <<EOF
cask "term-mesh" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/x-mesh/term-mesh/releases/download/v#{version}/term-mesh-macos-#{version}.dmg"
  name "term-mesh"
  desc "Terminal emulator with tabs, splits, and agent orchestration"
  homepage "https://github.com/x-mesh/term-mesh"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "term-mesh.app"
  binary "#{appdir}/term-mesh.app/Contents/Resources/bin/tm-agent"
  binary "#{appdir}/term-mesh.app/Contents/Resources/bin/term-mesh-run"

  # Fresh installs never run the uninstall stanza below, so a hand-installed
  # copy could still be holding the bundle when brew moves the new one in.
  # pkill matches on process name only, so unlike AppleScript it can never
  # put up a GUI prompt — see the uninstall comment for why that matters.
  preflight do
    quit = system_command "/usr/bin/pkill",
                          args:         ["-x", "term-mesh"],
                          must_succeed: false
    sleep 2 if quit.success?
  end

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/term-mesh.app"],
                   sudo: false
  end

  # Quit a running term-mesh before brew replaces the bundle. macOS
  # technically allows replacing a running .app via rename, but brew-cask
  # sometimes silently no-ops the move when the app holds an active
  # LaunchServices registration — leaving the user on the old version with a
  # "successfully installed" message.
  #
  # This belongs in \`uninstall quit:\`, which brew runs on upgrade while the
  # old bundle is still in place, so the bundle id resolves and the app exits
  # gracefully before the move.
  #
  # Do NOT do this from \`preflight\` with a name-based AppleScript
  # (\`tell application "term-mesh" to quit\`): on upgrade, preflight runs
  # *after* brew has already removed /Applications/term-mesh.app, macOS cannot
  # resolve the name, and it puts up a blocking "choose application" chooser.
  # The upgrade then hangs until a human dismisses it — \`must_succeed: false\`
  # does not help, because the call never returns at all.
  uninstall quit: "com.termmesh.app"

  zap trash: [
    "~/.term-mesh",
    "~/Library/Application Support/term-mesh",
    "~/Library/Caches/com.termmesh.app",
    "~/Library/Preferences/com.termmesh.app.plist",
    "~/Library/Saved Application State/com.termmesh.app.savedState",
  ]

  caveats <<~CAVEATS
    term-mesh is distributed without Apple notarization.
    This cask automatically removes the quarantine attribute so the app
    launches without a Gatekeeper warning. If you prefer to verify the
    Gatekeeper flow manually, run the following after install:

      xattr -dr com.apple.quarantine #{appdir}/term-mesh.app

    The bundled CLI helpers (tm-agent, term-mesh-run) are symlinked to
    #{HOMEBREW_PREFIX}/bin.
  CAVEATS
end
EOF

# Stage first so new files (e.g. initial Casks/term-mesh.rb) are visible
# to the change check — `git diff` alone ignores untracked paths.
git -C "$TAP_DIR" add "Casks/term-mesh.rb"

if git -C "$TAP_DIR" diff --cached --quiet --exit-code -- "Casks/term-mesh.rb"; then
  echo "==> No cask changes — nothing to commit"
  exit 0
fi

git -C "$TAP_DIR" -c user.name="term-mesh release bot" \
                   -c user.email="noreply@x-mesh.dev" \
  commit -m "term-mesh ${VERSION}"

if [[ -n "${DRY_RUN:-}" ]]; then
  echo "==> DRY_RUN set — skipping push"
  git -C "$TAP_DIR" --no-pager log -1
  exit 0
fi

echo "==> Pushing to ${TAP_REPO}@main"
git -C "$TAP_DIR" push origin main

echo ""
echo "================================================"
echo "  Homebrew cask updated"
echo "  Version: ${VERSION}"
echo "  sha256:  ${SHA256}"
echo "  Install: brew install --cask x-mesh/tap/term-mesh"
echo "================================================"

# Post-publish smoke test: do an actual `brew install` and confirm the
# resulting /Applications/term-mesh.app reports the version we just shipped.
# This catches the failure mode where publish + cask push both succeed but
# brew install silently leaves the user on the old version (see preflight
# block above for the race we hit on 0.100.0). Skip with SMOKE_TEST=0.
if [[ "${SMOKE_TEST:-1}" != "0" ]]; then
  echo ""
  echo "==> Smoke test: fresh brew install + version check"
  brew update >/dev/null 2>&1 || true
  brew uninstall --cask --force term-mesh >/dev/null 2>&1 || true
  if ! brew install --cask "${TAP_REPO%%/*}/tap/term-mesh"; then
    echo "ERROR: smoke test brew install failed" >&2
    exit 2
  fi
  ACTUAL=$(/usr/bin/defaults read /Applications/term-mesh.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo "<missing>")
  if [[ "$ACTUAL" != "$VERSION" ]]; then
    echo "ERROR: smoke test failed — installed=$ACTUAL expected=$VERSION" >&2
    echo "       The cask was published but `brew install` did not produce the expected version." >&2
    exit 2
  fi
  echo "==> Smoke test OK: /Applications/term-mesh.app reports $ACTUAL"
fi
