#!/usr/bin/env bash
# Behavioral tests for reload.sh's reclaim/deletion helpers.
#
# These functions `rm -rf` directories, and the only check on them used to be
# `bash -n` — which proves the file parses and nothing else. Every case here
# corresponds to a way one of them was observed to delete the wrong thing.
#
# Run: ./scripts/test-reload-cleanup.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ok   — $1"; }
no() { FAIL=$((FAIL + 1)); echo "  FAIL — $1" >&2; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }

# Each case gets a fresh sandbox and a fresh source of the helpers, so a
# function that mutates global state cannot leak into the next one.
sandbox() {
  SB="$(mktemp -d)"
  export TERMMESH_RELOAD_TMP_ROOT="$SB/tmp"
  export TERMMESH_BUILD_CACHE_ROOT="$SB/cache"
  export HOME="$SB/home"
  mkdir -p "$TERMMESH_RELOAD_TMP_ROOT" "$TERMMESH_BUILD_CACHE_ROOT" \
    "$HOME/Library/Application Support/term-mesh"
  # shellcheck source=/dev/null
  TERMMESH_RELOAD_LIB_ONLY=1 source "$SCRIPT_DIR/reload.sh"
}

seed_tag() {
  local tag="$1"
  mkdir -p "${TAG_TMP_ROOT}/term-mesh-${tag}/Build" "${CARGO_TARGET_ROOT}/${tag}/release"
  : > "${TAG_TMP_ROOT}/term-mesh-debug-${tag}.log"
  : > "${TAG_TMP_ROOT}/term-mesh-debug-${tag}.sock"
  : > "$HOME/Library/Application Support/term-mesh/term-meshd-dev-${tag}.sock"
}

echo "safe_managed_tag_path"
(
  sandbox
  safe_managed_tag_path "${TAG_TMP_ROOT}/term-mesh-alpha" && r=yes || r=no
  check "accepts a managed tag path" "$r" "yes"
  safe_managed_tag_path "${TAG_TMP_ROOT}/term-mesh-a/../../etc" && r=yes || r=no
  check "rejects traversal out of the managed root" "$r" "no"
  safe_managed_tag_path "${TAG_TMP_ROOT}/term-mesh-" && r=yes || r=no
  check "rejects an empty tag" "$r" "no"
  safe_managed_tag_path "/somewhere/else/term-mesh-alpha" && r=yes || r=no
  check "rejects a path outside the managed root" "$r" "no"
  ln -s /etc "${TAG_TMP_ROOT}/term-mesh-linked"
  safe_managed_tag_path "${TAG_TMP_ROOT}/term-mesh-linked" && r=yes || r=no
  check "rejects a symlinked tag directory" "$r" "no"
  exit $FAIL
) || FAIL=$((FAIL + $?))

echo "remove_tag_artifacts"
(
  sandbox
  seed_tag alpha
  seed_tag beta
  remove_tag_artifacts alpha
  [[ -e "${TAG_TMP_ROOT}/term-mesh-alpha" ]] && r=yes || r=no
  check "removes the tag's derived data" "$r" "no"
  [[ -e "${CARGO_TARGET_ROOT}/alpha" ]] && r=yes || r=no
  check "removes the tag's cargo target" "$r" "no"
  [[ -e "$HOME/Library/Application Support/term-mesh/term-meshd-dev-alpha.sock" ]] && r=yes || r=no
  check "removes the tag's daemon socket" "$r" "no"
  [[ -d "${TAG_TMP_ROOT}/term-mesh-beta" && -d "${CARGO_TARGET_ROOT}/beta" ]] && r=yes || r=no
  check "leaves another tag untouched" "$r" "yes"

  # The cargo target lives under a different root than the guarded path, so it
  # gets its own component check rather than inheriting the first one.
  mkdir -p "$SB/outside"; : > "$SB/outside/keep"
  ln -s "$SB/outside" "${CARGO_TARGET_ROOT}/linked"
  seed_tag linked
  rm -rf "${CARGO_TARGET_ROOT}/linked" 2>/dev/null || true
  ln -s "$SB/outside" "${CARGO_TARGET_ROOT}/linked"
  remove_tag_artifacts linked
  [[ -e "$SB/outside/keep" ]] && r=yes || r=no
  check "does not follow a symlinked cargo target out of the cache root" "$r" "yes"
  exit $FAIL
) || FAIL=$((FAIL + $?))

echo "reclaim_ended_tag_sessions"
(
  sandbox
  seed_tag ghost
  mkdir -p "$TAG_SESSION_ROOT"
  echo 999999 > "${TAG_SESSION_ROOT}/ghost.session"   # a PID that is not running
  tag_is_running() { return 1; }
  path_in_use() { return 1; }
  reclaim_ended_tag_sessions other >/dev/null
  [[ -e "${TAG_TMP_ROOT}/term-mesh-ghost" ]] && r=yes || r=no
  check "reclaims a tag whose session really ended" "$r" "no"
  exit $FAIL
) || FAIL=$((FAIL + $?))

(
  sandbox
  seed_tag live
  mkdir -p "$TAG_SESSION_ROOT"
  # The manifest holds a stale PID — the app relaunched without refreshing it.
  echo 999999 > "${TAG_SESSION_ROOT}/live.session"
  tag_is_running() { [[ "$1" == "live" ]]; }
  path_in_use() { return 1; }
  reclaim_ended_tag_sessions other >/dev/null
  [[ -d "${TAG_TMP_ROOT}/term-mesh-live" ]] && r=yes || r=no
  check "keeps a tag whose app is still running despite a stale manifest PID" "$r" "yes"
  exit $FAIL
) || FAIL=$((FAIL + $?))

(
  sandbox
  seed_tag socketed
  mkdir -p "$TAG_SESSION_ROOT"
  echo 999999 > "${TAG_SESSION_ROOT}/socketed.session"
  tag_is_running() { return 1; }
  path_in_use() { return 0; }
  reclaim_ended_tag_sessions other >/dev/null
  [[ -d "${TAG_TMP_ROOT}/term-mesh-socketed" ]] && r=yes || r=no
  check "keeps a tag whose daemon socket is still in use" "$r" "yes"
  exit $FAIL
) || FAIL=$((FAIL + $?))

echo "cleanup_failed_build"
(
  sandbox
  seed_tag working
  TAG_SLUG=working
  DERIVED_DATA="${TAG_TMP_ROOT}/term-mesh-working"
  MANAGED_DERIVED=1
  BUILD_LAUNCHED=0
  DERIVED_PREEXISTING=1        # the build that is already working
  tag_is_running() { return 1; }
  (exit 1); cleanup_failed_build 2>/dev/null || true
  [[ -d "${TAG_TMP_ROOT}/term-mesh-working" ]] && r=yes || r=no
  check "a failed rebuild keeps the previous build's derived data" "$r" "yes"
  exit $FAIL
) || FAIL=$((FAIL + $?))

(
  sandbox
  seed_tag fresh
  TAG_SLUG=fresh
  DERIVED_DATA="${TAG_TMP_ROOT}/term-mesh-fresh"
  MANAGED_DERIVED=1
  BUILD_LAUNCHED=0
  DERIVED_PREEXISTING=0        # this run created it
  tag_is_running() { return 1; }
  (exit 1); cleanup_failed_build 2>/dev/null || true
  [[ -e "${TAG_TMP_ROOT}/term-mesh-fresh" ]] && r=yes || r=no
  check "a first build that failed is reclaimed" "$r" "no"
  exit $FAIL
) || FAIL=$((FAIL + $?))

(
  sandbox
  seed_tag running
  TAG_SLUG=running
  DERIVED_DATA="${TAG_TMP_ROOT}/term-mesh-running"
  MANAGED_DERIVED=1
  BUILD_LAUNCHED=0
  DERIVED_PREEXISTING=0
  tag_is_running() { return 0; }   # an app is live in that directory anyway
  (exit 1); cleanup_failed_build 2>/dev/null || true
  [[ -d "${TAG_TMP_ROOT}/term-mesh-running" ]] && r=yes || r=no
  check "never reclaims while that tag's app is running" "$r" "yes"
  exit $FAIL
) || FAIL=$((FAIL + $?))

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "reload cleanup: all checks passed"
  exit 0
fi
echo "reload cleanup: ${FAIL} check(s) failed" >&2
exit 1
