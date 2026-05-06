#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "==> Initializing submodules..."
git submodule update --init --recursive

echo "==> Checking for zig..."
if ! command -v zig &> /dev/null; then
    echo "Error: zig is not installed."
    echo "Install via: brew install zig"
    exit 1
fi

echo "==> Checking for Metal Toolchain..."
if ! xcrun metal --version &> /dev/null; then
    echo "==> Metal Toolchain not found, downloading..."
    xcodebuild -downloadComponent MetalToolchain
fi

echo "==> Cleaning problematic xcframework-* tags in ghostty submodule..."
git -C ghostty tag -l 'xcframework-*' | while read -r t; do git -C ghostty tag -d "$t"; done 2>/dev/null || true

GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
CACHE_ROOT="${TERMMESH_GHOSTTYKIT_CACHE_DIR:-$HOME/.cache/term-mesh/ghosttykit}"
CACHE_DIR="$CACHE_ROOT/$GHOSTTY_SHA"
CACHE_XCFRAMEWORK="$CACHE_DIR/GhosttyKit.xcframework"
LOCAL_XCFRAMEWORK="$PROJECT_DIR/ghostty/macos/GhosttyKit.xcframework"
LOCAL_SHA_STAMP="$LOCAL_XCFRAMEWORK/.ghostty_sha"
LOCK_DIR="$CACHE_ROOT/$GHOSTTY_SHA.lock"

mkdir -p "$CACHE_ROOT"

echo "==> Ghostty submodule commit: $GHOSTTY_SHA"

LOCK_TIMEOUT=300
LOCK_START=$SECONDS
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if (( SECONDS - LOCK_START > LOCK_TIMEOUT )); then
        echo "==> Lock stale (>${LOCK_TIMEOUT}s), removing and retrying..."
        rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
        continue
    fi
    echo "==> Waiting for GhosttyKit cache lock for $GHOSTTY_SHA..."
    sleep 1
done
trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

if [ -d "$CACHE_XCFRAMEWORK" ]; then
    echo "==> Reusing cached GhosttyKit.xcframework"
else
    # Only reuse local xcframework if its SHA stamp matches the current ghostty commit.
    # Without this check, a stale build from a previous commit could be cached under
    # the wrong SHA, producing ABI mismatches.
    LOCAL_SHA=""
    if [ -f "$LOCAL_SHA_STAMP" ]; then
        LOCAL_SHA="$(cat "$LOCAL_SHA_STAMP")"
    fi

    SEEDED_FROM=""
    if [ -d "$LOCAL_XCFRAMEWORK" ] && [ "$LOCAL_SHA" = "$GHOSTTY_SHA" ]; then
        echo "==> Seeding cache from existing local GhosttyKit.xcframework (SHA matches)"
        SEEDED_FROM="local"
    fi

    # Try the prebuilt GitHub Release artifact next. Skips a slow (and
    # zig-toolchain-dependent) local build when CI has already built
    # this exact ghostty SHA. Disable with TERMMESH_GHOSTTY_NO_PREBUILT=1.
    if [ -z "$SEEDED_FROM" ] && [ "${TERMMESH_GHOSTTY_NO_PREBUILT:-0}" != "1" ]; then
        PREBUILT_REPO="${TERMMESH_GHOSTTY_PREBUILT_REPO:-x-mesh/term-mesh}"
        PREBUILT_TAG="ghostty-prebuilt-$GHOSTTY_SHA"
        PREBUILT_ASSET="GhosttyKit-$GHOSTTY_SHA.tar.gz"
        PREBUILT_URL="https://github.com/$PREBUILT_REPO/releases/download/$PREBUILT_TAG/$PREBUILT_ASSET"
        TMP_DL_DIR="$(mktemp -d "$CACHE_ROOT/.ghosttykit-dl.XXXXXX")"
        echo "==> Trying prebuilt artifact: $PREBUILT_URL"
        if curl -fL --silent --show-error "$PREBUILT_URL" -o "$TMP_DL_DIR/$PREBUILT_ASSET" 2>"$TMP_DL_DIR/curl.err"; then
            if tar -xzf "$TMP_DL_DIR/$PREBUILT_ASSET" -C "$TMP_DL_DIR" 2>"$TMP_DL_DIR/tar.err"; then
                if [ -d "$TMP_DL_DIR/GhosttyKit.xcframework" ]; then
                    rm -rf "$LOCAL_XCFRAMEWORK"
                    mkdir -p "$(dirname "$LOCAL_XCFRAMEWORK")"
                    mv "$TMP_DL_DIR/GhosttyKit.xcframework" "$LOCAL_XCFRAMEWORK"
                    echo "$GHOSTTY_SHA" > "$LOCAL_SHA_STAMP"
                    SEEDED_FROM="release"
                    echo "==> Fetched prebuilt GhosttyKit.xcframework from $PREBUILT_TAG"
                else
                    echo "==> Prebuilt tarball did not contain GhosttyKit.xcframework; falling back to local build"
                fi
            else
                echo "==> Prebuilt tarball failed to extract ($(cat "$TMP_DL_DIR/tar.err" 2>/dev/null)); falling back to local build"
            fi
        else
            echo "==> No prebuilt available for $GHOSTTY_SHA; falling back to local build"
        fi
        rm -rf "$TMP_DL_DIR"
    fi

    if [ -z "$SEEDED_FROM" ]; then
        echo "==> Building GhosttyKit.xcframework (this may take a few minutes)..."
        (
            cd ghostty
            zig build -Demit-xcframework=true -Doptimize=ReleaseFast
        )
        # Stamp the build output with the SHA it was built from
        echo "$GHOSTTY_SHA" > "$LOCAL_SHA_STAMP"
        SEEDED_FROM="zig"
    fi

    if [ ! -d "$LOCAL_XCFRAMEWORK" ]; then
        echo "Error: GhosttyKit.xcframework not found at $LOCAL_XCFRAMEWORK"
        exit 1
    fi

    TMP_DIR="$(mktemp -d "$CACHE_ROOT/.ghosttykit-tmp.XXXXXX")"
    mkdir -p "$CACHE_DIR"
    cp -R "$LOCAL_XCFRAMEWORK" "$TMP_DIR/GhosttyKit.xcframework"
    rm -rf "$CACHE_XCFRAMEWORK"
    mv "$TMP_DIR/GhosttyKit.xcframework" "$CACHE_XCFRAMEWORK"
    rmdir "$TMP_DIR"
    echo "==> Cached GhosttyKit.xcframework at $CACHE_XCFRAMEWORK (source: $SEEDED_FROM)"
fi

echo "==> Creating symlink for GhosttyKit.xcframework..."
ln -sfn "$CACHE_XCFRAMEWORK" GhosttyKit.xcframework

echo "==> Setup complete!"
echo ""
echo "You can now build and run the app:"
echo "  xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination 'platform=macOS' build"
echo ""
echo "Or use the reload script:"
echo "  ./scripts/reload.sh --tag first-run"
