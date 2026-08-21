#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
PROJECT="$SANDBOX/project"
CACHE="$SANDBOX/cache"
MOCK_BIN="$SANDBOX/bin"
SHA=0123456789abcdef0123456789abcdef01234567
OTHER=89abcdef0123456789abcdef0123456789abcdef
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
expect() {
    local label="$1" want="$2" actual
    if ghostty_kit_is_consistent "$PROJECT"; then actual=pass; else actual=fail; fi
    if [ "$actual" = "$want" ]; then ok "$label"; else bad "$label (wanted $want, got $actual)"; fi
}

mkdir -p "$PROJECT/ghostty" "$CACHE/$SHA/GhosttyKit.xcframework/macos-arm64_x86_64" "$MOCK_BIN"
printf 'header v1\n' > "$PROJECT/ghostty.h"
printf 'header v1\n' > "$CACHE/$SHA/GhosttyKit.xcframework/ghostty.h"
printf '%s\n' "$SHA" > "$CACHE/$SHA/GhosttyKit.xcframework/.ghostty_sha"
: > "$CACHE/$SHA/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a"
ln -s "$CACHE/$SHA/GhosttyKit.xcframework" "$PROJECT/GhosttyKit.xcframework"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$*" == *"rev-parse HEAD:ghostty" ]]; then' \
    '  printf "%s\n" "${MOCK_PARENT_SHA:?}"' \
    'elif [[ "$*" == *"rev-parse HEAD" ]]; then' \
    '  printf "%s\n" "${MOCK_WORKTREE_SHA:?}"' \
    'else' \
    '  exit 2' \
    'fi' > "$MOCK_BIN/git"
chmod +x "$MOCK_BIN/git"
export PATH="$MOCK_BIN:$PATH" MOCK_PARENT_SHA="$SHA" MOCK_WORKTREE_SHA="$SHA"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/ghostty-abi.sh"

expect "matching pin, checkout, stamp, symlink, archive, and header" pass

ln -s "$CACHE/$SHA/GhosttyKit.xcframework" "$SANDBOX/shared-GhosttyKit.xcframework"
ln -sfn "$SANDBOX/shared-GhosttyKit.xcframework" "$PROJECT/GhosttyKit.xcframework"
expect "accepts a worktree link through the main checkout symlink" pass
ln -sfn "$CACHE/$SHA/GhosttyKit.xcframework" "$PROJECT/GhosttyKit.xcframework"

MOCK_WORKTREE_SHA="$OTHER"
expect "rejects a drifted submodule checkout" fail
MOCK_WORKTREE_SHA="$SHA"

printf '%s\n' "$OTHER" > "$CACHE/$SHA/GhosttyKit.xcframework/.ghostty_sha"
expect "rejects a stale framework stamp" fail
printf '%s\n' "$SHA" > "$CACHE/$SHA/GhosttyKit.xcframework/.ghostty_sha"

mkdir -p "$CACHE/$OTHER"
ln -sfn "$CACHE/$OTHER/GhosttyKit.xcframework" "$PROJECT/GhosttyKit.xcframework"
expect "rejects a symlink whose cache SHA is stale" fail
ln -sfn "$CACHE/$SHA/GhosttyKit.xcframework" "$PROJECT/GhosttyKit.xcframework"

mv "$CACHE/$SHA/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a" "$SANDBOX/archive"
expect "rejects a framework without a static archive" fail
mv "$SANDBOX/archive" "$CACHE/$SHA/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a"

printf 'header v2\n' > "$CACHE/$SHA/GhosttyKit.xcframework/ghostty.h"
expect "rejects a C API header mismatch" fail

printf '\npassed=%d failed=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
