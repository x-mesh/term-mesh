#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Activate project git hooks (commit-msg strips fenced code-block markers that
# LLM agents tend to wrap commit messages in). core.hooksPath cannot be pinned
# inside the repo, so it must be set per clone — do it here idempotently so the
# strip defense is never silently missing on a fresh machine/agent environment.
echo "==> Activating project git hooks (.githooks)..."
git config core.hooksPath .githooks

echo "==> Initializing submodules..."
git submodule update --init --recursive

# zig and llvm-libtool-darwin are only needed for a local GhosttyKit build;
# they are checked inside the local-build branch below so a prebuilt/cached
# xcframework can be used without them.

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
        # A local build needs zig 0.15.x — ghostty's build.zig rejects 0.16 —
        # and llvm-libtool-darwin. macOS /usr/bin/libtool silently skips
        # 8-byte-misaligned archive members (warning only), which drops
        # libghostty_zcu.o and erases every ghostty_surface_* symbol from the
        # combined xcframework. llvm-libtool-darwin keeps misaligned members.
        #
        # Verify each zig candidate's *actual* version, not just the path: a
        # `brew upgrade zig` to 0.16 can leave /opt/homebrew/opt/zig@0.15 as a
        # stale symlink pointing at the 0.16 keg, and a broken brew keg can
        # resolve to an unusable binary — both pass a path-only check and then
        # fail the build. Override with ZIG=/path/to/zig-0.15.x/zig; standalone
        # tarball extracts under ~/.local and ~/zig are searched too.
        _zig_is_0_15() { [ -x "$1" ] && "$1" version 2>/dev/null | grep -q '^0\.15\.'; }
        ZIG_BIN=""
        for cand in \
            "${ZIG:-}" \
            /opt/homebrew/opt/zig@0.15/bin/zig /usr/local/opt/zig@0.15/bin/zig \
            "$HOME"/.local/zig-0.15*/zig "$HOME"/zig/zig-*-0.15*/zig \
            "$(command -v zig 2>/dev/null)"; do
            [ -n "$cand" ] || continue
            if _zig_is_0_15 "$cand"; then ZIG_BIN="$cand"; break; fi
        done
        if [ -z "$ZIG_BIN" ]; then
            echo "Error: zig 0.15.x is required to build GhosttyKit (ghostty rejects 0.16)."
            echo "Install via: brew install zig@0.15, or set ZIG=/path/to/zig-0.15.x/zig"
            echo "If zig@0.15 is installed but resolves to 0.16 (stale keg symlink):"
            echo "  brew unlink zig 2>/dev/null; brew link --overwrite --force zig@0.15"
            exit 1
        fi

        LLVM_BIN=""
        for cand in /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin; do
            [ -x "$cand/llvm-libtool-darwin" ] && { LLVM_BIN="$cand"; break; }
        done
        if [ -z "$LLVM_BIN" ] && command -v llvm-libtool-darwin &> /dev/null; then
            LLVM_BIN="$(dirname "$(command -v llvm-libtool-darwin)")"
        fi
        if [ -z "$LLVM_BIN" ]; then
            echo "Error: llvm-libtool-darwin is required to build GhosttyKit."
            echo "Without it macOS /usr/bin/libtool silently drops ghostty_surface_* symbols."
            echo "Install via: brew install llvm"
            exit 1
        fi

        # Pin the macOS SDK explicitly. A standalone zig tarball can latch onto
        # a stale/broken CommandLineTools SDK during auto-detection and fail to
        # link libSystem (undefined _free / _dispatch_queue_create / ...). Force
        # the SDK that `xcrun --sdk macosx` resolves (the full Xcode SDK when
        # available) plus the matching developer dir.
        SDKROOT_VAL="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
        DEVDIR_VAL="$(xcode-select -p 2>/dev/null || true)"
        echo "==> Building GhosttyKit.xcframework with $ZIG_BIN + $LLVM_BIN/llvm-libtool-darwin (this may take a few minutes)..."
        [ -n "$SDKROOT_VAL" ] && echo "==> Using SDKROOT=$SDKROOT_VAL"
        (
            cd ghostty
            export PATH="$LLVM_BIN:$PATH"
            [ -n "$SDKROOT_VAL" ] && export SDKROOT="$SDKROOT_VAL"
            [ -n "$DEVDIR_VAL" ] && export DEVELOPER_DIR="$DEVDIR_VAL"
            "$ZIG_BIN" build -Demit-xcframework=true -Doptimize=ReleaseFast
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
