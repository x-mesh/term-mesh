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
  # put up a GUI prompt — see the uninstall comment for why that matters. The
  # daemon deliberately outlives an ordinary quit while serving peers, but an
  # upgrade must replace it or the new app adopts an old protocol process.
  #
  # Scope it to the bundle this install actually replaces. Matching on process
  # name alone means an unguarded preflight kills every running term-mesh on
  # the machine, including one launched from outside appdir that this install
  # never touches. That is what lets an isolated \`--appdir\` install — the
  # release smoke test — run beside a live app instead of taking it down.
  preflight do
    if File.exist?("#{appdir}/term-mesh.app")
      quit = system_command "/usr/bin/pkill",
                            args:         ["-x", "term-mesh"],
                            must_succeed: false
      sleep 2 if quit.success?
      system_command "/usr/bin/pkill",
                     args: ["-f", "^#{appdir}/term-mesh[.]app/Contents/Resources/bin/term-meshd$"],
                     must_succeed: false
    end
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
  uninstall quit: "com.termmesh.app",
            script: {
              executable: "/usr/bin/pkill",
              args: ["-f", "^#{appdir}/term-mesh[.]app/Contents/Resources/bin/term-meshd$"],
              must_succeed: false,
              sudo: false,
            }

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

# Post-publish smoke test: confirm that installing this cask produces the
# version we just shipped. This catches the failure mode where publish + cask
# push both succeed but brew install silently leaves the user on the old
# version (see preflight block above for the race we hit on 0.100.0).
#
# The default path verifies the published *artifact* and touches nothing on
# this machine. `brew install` cannot be made safe to run here: it replaces the
# bundle in /Applications, rewrites a machine-wide Caskroom receipt, and its
# preflight quits a running term-mesh — the maintainer's own session. Isolating
# it behind `--appdir` does not fix the receipt, which a later `brew upgrade`
# would then follow into a throwaway directory.
#
# This used to install whenever `pgrep` found no running app, so a missed match
# cost the maintainer their session. Process detection is no longer in the
# blast path at all: installing is opt-in.
#
#   SMOKE_TEST=0      skip entirely
#   SMOKE_TEST=full   really install — replaces /Applications/term-mesh.app and
#                     quits a running app. Use a test machine.
#   otherwise         verify the artifact only; changes nothing locally
if [[ "${SMOKE_TEST:-1}" != "0" ]]; then
  echo ""
  # The cask was pushed seconds ago; `brew update` can still serve the previous
  # revision, and then the checks below fail on a release that is actually
  # fine. Wait for the tap to report the version we just published.
  for _ in 1 2 3 4 5 6; do
    brew update >/dev/null 2>&1 || true
    if brew info --cask "${TAP_REPO%%/*}/tap/term-mesh" 2>/dev/null | head -1 | grep -q "$VERSION"; then
      break
    fi
    sleep 5
  done

  echo "==> Smoke test: verifying the published artifact"

  # 1. The DMG the cask points at carries this version. The sha256 checked
  #    below ties the cask to this exact file, so the bundle inside it is what
  #    a user receives.
  MOUNT_POINT=$(mktemp -d -t term-mesh-smoke)
  if ! hdiutil attach "$DMG_PATH" -nobrowse -readonly -quiet -mountpoint "$MOUNT_POINT"; then
    echo "ERROR: smoke test could not mount $DMG_PATH" >&2
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    exit 2
  fi
  ACTUAL=$(/usr/bin/defaults read "$MOUNT_POINT/term-mesh.app/Contents/Info" \
    CFBundleShortVersionString 2>/dev/null || echo "<missing>")
  hdiutil detach "$MOUNT_POINT" -quiet || true
  rmdir "$MOUNT_POINT" 2>/dev/null || true

  if [[ "$ACTUAL" != "$VERSION" ]]; then
    echo "ERROR: smoke test failed — DMG bundle reports $ACTUAL, expected $VERSION" >&2
    echo "       The cask points at a DMG that does not carry this version." >&2
    exit 2
  fi

  # 2. The cask the tap serves is the one holding that file's hash.
  TAP_SHA=$(brew info --cask --json=v2 "${TAP_REPO%%/*}/tap/term-mesh" 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["casks"][0].get("sha256",""))' \
    2>/dev/null || echo "")
  if [[ -n "$TAP_SHA" && "$TAP_SHA" != "$SHA256" ]]; then
    echo "ERROR: smoke test failed — tap serves sha256 $TAP_SHA, published DMG is $SHA256" >&2
    exit 2
  fi

  # 3. brew can load the cask and actually retrieve what it publishes. `fetch`
  #    runs the same download and checksum path as `install` and stops before
  #    anything is staged, so a missing release asset, an unreachable URL, or a
  #    sha256 that does not match the uploaded file all fail right here —
  #    without staging a bundle or writing a receipt.
  if ! brew fetch --cask "${TAP_REPO%%/*}/tap/term-mesh" >/dev/null; then
    echo "ERROR: smoke test failed — brew could not fetch the published cask" >&2
    echo "       The release asset is missing, unreachable, or its sha256 does" >&2
    echo "       not match the file GitHub is serving." >&2
    exit 2
  fi

  echo "==> Smoke test OK: DMG reports $ACTUAL, tap sha256 matches, brew fetch succeeds"

  if [[ "${SMOKE_TEST:-1}" == "full" ]]; then
    echo ""
    # Match the bundle's own executable path, not the bare name: `pgrep -f
    # term-mesh` also matches this script, every tm-agent, and any editor with
    # the word in its command line.
    RUNNING_PIDS=$(pgrep -f '/term-mesh\.app/Contents/MacOS/term-mesh' 2>/dev/null || true)
    if [[ -n "$RUNNING_PIDS" ]]; then
      echo "==> SMOKE_TEST=full: quitting running term-mesh (pid $(echo "$RUNNING_PIDS" | tr '\n' ' '))"
    fi
    echo "==> SMOKE_TEST=full: installing over /Applications/term-mesh.app"
    brew uninstall --cask --force term-mesh >/dev/null 2>&1 || true
    if ! brew install --cask "${TAP_REPO%%/*}/tap/term-mesh"; then
      echo "ERROR: smoke test brew install failed" >&2
      exit 2
    fi
    ACTUAL=$(/usr/bin/defaults read /Applications/term-mesh.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo "<missing>")
    if [[ "$ACTUAL" != "$VERSION" ]]; then
      echo "ERROR: smoke test failed — installed=$ACTUAL expected=$VERSION" >&2
      # Single quotes: backticks inside a double-quoted string are command
      # substitution, so this line used to *run* `brew install` (with no
      # arguments) and print its usage error on top of the real failure.
      echo '       The cask was published but `brew install` did not produce the expected version.' >&2
      echo "       Usually a stale tap: 'brew update' then reinstall." >&2
      exit 2
    fi
    echo "==> Smoke test OK: /Applications/term-mesh.app reports $ACTUAL"
  fi
fi
