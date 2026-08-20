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

# `git submodule update` above aligns a drifted worktree on its own, and fails
# loudly on a dirty one. It stays silent in one case: a submodule carrying
# local commits. Verify the worktree really landed on the pin, because every
# ABI decision below keys off it.
PINNED_GHOSTTY_SHA="$(git rev-parse HEAD:ghostty 2>/dev/null || true)"
GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
if [ -n "$PINNED_GHOSTTY_SHA" ] && [ "$PINNED_GHOSTTY_SHA" != "$GHOSTTY_SHA" ]; then
    echo "ERROR: ghostty submodule is not on the commit this repo pins." >&2
    echo "  pinned by parent  : $PINNED_GHOSTTY_SHA" >&2
    echo "  submodule worktree: $GHOSTTY_SHA" >&2
    echo "  Fix with ./scripts/sync-submodules.sh, then re-run this script." >&2
    exit 1
fi

# Keep the committed root ghostty.h in sync with the ghostty submodule header.
# Swift compiles the ghostty C API *declarations* from this root copy (imported
# via term-mesh-Bridging-Header.h); the xcframework only supplies libghostty.a
# for linking. A stale root header causes ABI-mismatch build errors after a
# submodule bump (e.g. read_clipboard_cb void vs bool -> "cannot convert 'Bool'
# to closure result type 'Void'"). The root copy carries no local edits, so a
# straight sync is safe.
_SUBMODULE_GHOSTTY_H="$PROJECT_DIR/ghostty/include/ghostty.h"
_ROOT_GHOSTTY_H="$PROJECT_DIR/ghostty.h"
if [ -f "$_SUBMODULE_GHOSTTY_H" ] && ! cmp -s "$_SUBMODULE_GHOSTTY_H" "$_ROOT_GHOSTTY_H"; then
    cp "$_SUBMODULE_GHOSTTY_H" "$_ROOT_GHOSTTY_H"
    echo "==> Synced root ghostty.h from submodule (Swift bridging-header declarations)"
fi

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

# GHOSTTY_SHA was resolved and verified against the parent's pin above.
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
    # Mark the cache entry as used so pruning below evicts by real recency
    # rather than by when the framework happened to be built.
    touch "$CACHE_DIR"
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
        # A local build needs zig 0.16.x — ghostty's build.zig.zon pins
        # minimum_zig_version 0.16.0 since the 2026-08 upstream sync — and
        # llvm-libtool-darwin. macOS /usr/bin/libtool silently skips
        # 8-byte-misaligned archive members (warning only), which drops
        # libghostty_zcu.o and erases every ghostty_surface_* symbol from the
        # combined xcframework. llvm-libtool-darwin keeps misaligned members.
        #
        # Verify each zig candidate's *actual* version, not just the path:
        # versioned brew kegs can be stale symlinks and a broken keg can
        # resolve to an unusable binary — both pass a path-only check and then
        # fail the build. Override with ZIG=/path/to/zig-0.16.x/zig; standalone
        # tarball extracts under ~/.local and ~/zig are searched too.
        _zig_is_0_16() { [ -x "$1" ] && "$1" version 2>/dev/null | grep -q '^0\.16\.'; }
        ZIG_BIN=""
        for cand in \
            "${ZIG:-}" \
            "$(command -v zig 2>/dev/null)" \
            /opt/homebrew/opt/zig/bin/zig /usr/local/opt/zig/bin/zig \
            /opt/homebrew/opt/zig@0.16/bin/zig /usr/local/opt/zig@0.16/bin/zig \
            "$HOME"/.local/zig-0.16*/zig "$HOME"/zig/zig-*-0.16*/zig; do
            [ -n "$cand" ] || continue
            if _zig_is_0_16 "$cand"; then ZIG_BIN="$cand"; break; fi
        done
        if [ -z "$ZIG_BIN" ]; then
            echo "Error: zig 0.16.x is required to build GhosttyKit (ghostty pins minimum_zig_version 0.16.0)."
            echo "Install via: brew install zig, or set ZIG=/path/to/zig-0.16.x/zig"
            exit 1
        fi

        LLVM_BIN=""
        # llvm-libtool-darwin lives in the llvm keg's bin. Homebrew's unversioned
        # `llvm` links into opt/llvm, but versioned kegs (llvm@21, llvm@20) only
        # appear under opt/llvm@NN or Cellar and are missed by a bare opt/llvm
        # check — probe those too, plus `brew --prefix` and PATH.
        LLVM_CANDS=(
            /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin
            /opt/homebrew/opt/llvm@21/bin /opt/homebrew/opt/llvm@20/bin
            /usr/local/opt/llvm@21/bin /usr/local/opt/llvm@20/bin
        )
        for _kegbin in /opt/homebrew/Cellar/llvm@*/*/bin /opt/homebrew/Cellar/llvm/*/bin \
                       /usr/local/Cellar/llvm@*/*/bin /usr/local/Cellar/llvm/*/bin; do
            [ -d "$_kegbin" ] && LLVM_CANDS+=("$_kegbin")
        done
        for _f in llvm llvm@21 llvm@20; do
            _p="$(brew --prefix "$_f" 2>/dev/null)" && [ -n "$_p" ] && LLVM_CANDS+=("$_p/bin")
        done
        for cand in "${LLVM_CANDS[@]}"; do
            [ -x "$cand/llvm-libtool-darwin" ] && { LLVM_BIN="$cand"; break; }
        done
        if [ -z "$LLVM_BIN" ] && command -v llvm-libtool-darwin &> /dev/null; then
            LLVM_BIN="$(dirname "$(command -v llvm-libtool-darwin)")"
        fi
        if [ -z "$LLVM_BIN" ]; then
            echo "Error: llvm-libtool-darwin is required to build GhosttyKit."
            echo "Without it macOS /usr/bin/libtool silently drops ghostty_surface_* symbols."
            echo "Install via: brew install llvm   (llvm@21 / llvm@20 also work)"
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

# Final implementation + ABI assert. This verifies not only the declarations
# Swift compiles, but also that the linked archive was built from this exact
# ghostty commit.
# shellcheck source=lib/ghostty-abi.sh
. "$SCRIPT_DIR/lib/ghostty-abi.sh"
if ! ghostty_kit_is_consistent "$PROJECT_DIR"; then
    echo "ERROR: GhosttyKit check failed after setup." >&2
    ghostty_kit_report "$PROJECT_DIR"
    exit 1
fi

# Each cached SHA is ~540M and nothing ever removed the old ones, so a repo
# that follows ghostty for a while quietly loses gigabytes to frameworks no
# checkout references. Keep the most recently used entries and drop the rest.
prune_ghosttykit_cache() {
    local keep="${TERMMESH_GHOSTTYKIT_CACHE_KEEP:-3}"
    if ! [[ "$keep" =~ ^[0-9]+$ ]] || [ "$keep" -le 0 ]; then
        return 0
    fi

    local linked_sha=""
    if [ -L "$PROJECT_DIR/GhosttyKit.xcframework" ]; then
        linked_sha="$(basename "$(dirname "$(readlink "$PROJECT_DIR/GhosttyKit.xcframework")")")"
    fi

    local kept=0
    local entry path sha
    while IFS= read -r entry; do
        path="${entry#* }"
        sha="$(basename "$path")"
        # Only real cache entries: SHA-named directories. Lock dirs and the
        # mktemp staging dirs share this root and must be left alone.
        if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
            continue
        fi
        # Never evict the SHA in play, the one the symlink resolves to, or one
        # a concurrent setup.sh is still populating.
        if [ "$sha" = "$GHOSTTY_SHA" ] || [ "$sha" = "$linked_sha" ] || [ -d "$CACHE_ROOT/$sha.lock" ]; then
            kept=$((kept + 1))
            continue
        fi
        if [ "$kept" -lt "$keep" ]; then
            kept=$((kept + 1))
            continue
        fi
        rm -rf "$path"
        echo "==> Pruned unused GhosttyKit cache ${sha:0:12}"
    done < <(find "$CACHE_ROOT" -mindepth 1 -maxdepth 1 -type d -exec stat -f '%m %N' {} + 2>/dev/null | sort -rn)
}

prune_ghosttykit_cache

echo "==> Generating BuildInfo.swift..."
"$PROJECT_DIR/scripts/generate-build-info.sh"

echo "==> Setup complete!"
echo ""
echo "You can now build and run the app:"
echo "  xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination 'platform=macOS' build"
echo ""
echo "Or use the reload script:"
echo "  ./scripts/reload.sh --tag first-run"
