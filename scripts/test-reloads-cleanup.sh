#!/usr/bin/env bash
# Behavioral tests for reloads.sh --cleanup.
#
# It `rm -rf`s a derived-data directory, and `bash -n` proves the file parses
# and nothing else. This drives the real command against a sandbox root: the
# reclaim path, every rejection the path guard owes us, and the socket path the
# staging app actually creates.
#
# Run: ./scripts/test-reloads-cleanup.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/reloads.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

run_cleanup() {
  TERMMESH_RELOAD_TMP_ROOT="$SANDBOX" bash "$SCRIPT" "$@" 2>&1
}

echo "== syntax =="
if bash -n "$SCRIPT"; then ok "parses"; else bad "parses"; fi

echo "== reclaims its own managed derived data =="
DD="$SANDBOX/term-mesh-staging-testtag"
mkdir -p "$DD/Build/Products/Release"
echo x > "$DD/Build/Products/Release/marker"
: > "$SANDBOX/term-mesh-staging-testtag.sock"
OUT="$(run_cleanup --tag testtag --cleanup)"
check "derived data removed" "$([[ -e "$DD" ]] && echo present || echo gone)" "gone"
check "socket removed" "$([[ -e "$SANDBOX/term-mesh-staging-testtag.sock" ]] && echo present || echo gone)" "gone"
case "$OUT" in *"reclaimed staging build testtag"*) ok "reports reclaim" ;; *) bad "reports reclaim: $OUT" ;; esac

echo "== refuses a caller-owned --derived-data =="
KEEP="$SANDBOX/caller-owned"
mkdir -p "$KEEP"
OUT="$(run_cleanup --tag testtag --derived-data "$KEEP" --cleanup)"
check "caller path kept" "$([[ -d "$KEEP" ]] && echo present || echo gone)" "present"
case "$OUT" in *"caller-owned"*) ok "explains why it was kept" ;; *) bad "explains why: $OUT" ;; esac

echo "== path guard rejects everything it should =="
# sanitize_path already neutralises a traversal-shaped --tag, so driving this
# through the CLI would pass without the guard existing at all. Call the guard
# directly instead, so a regression in it actually fails this test.
guard() {
  TERMMESH_RELOAD_TMP_ROOT="$SANDBOX" bash -c '
    set -uo pipefail
    STAGING_TMP_ROOT="'"$SANDBOX"'"
    '"$(sed -n '/^safe_managed_staging_path()/,/^}/p' "$SCRIPT")"'
    if safe_managed_staging_path "$1"; then echo accept; else echo reject; fi
  ' _ "$1"
}
mkdir -p "$SANDBOX/term-mesh-staging-good"
ln -sfn /etc "$SANDBOX/term-mesh-staging-link"
check "managed path"        "$(guard "$SANDBOX/term-mesh-staging-good")"      "accept"
check "traversal"           "$(guard "$SANDBOX/term-mesh-staging-a/../../x")" "reject"
check "nested component"    "$(guard "$SANDBOX/term-mesh-staging-a/b")"       "reject"
check "symlink"             "$(guard "$SANDBOX/term-mesh-staging-link")"      "reject"
check "outside root"        "$(guard "/tmp/term-mesh-staging-elsewhere")"     "reject"
check "root itself"         "$(guard "$SANDBOX")"                             "reject"
check "wrong prefix"        "$(guard "$SANDBOX/term-mesh-debug-good")"        "reject"
check "empty tag"           "$(guard "$SANDBOX/term-mesh-staging-")"          "reject"

echo "== --cleanup requires --tag =="
OUT="$(run_cleanup --cleanup)"; RC=$?
check "exit code" "$RC" "1"
case "$OUT" in *"requires --tag"*) ok "explains the requirement" ;; *) bad "explains: $OUT" ;; esac

echo "== socket path matches SocketControlSettings.defaultSocketPath =="
# com.termmesh.app.staging.<tag> -> /tmp/term-mesh-staging-<tag>.sock, with '.'
# in the bundle tag normalised to '-' exactly as sanitizeTag does.
probe_socket() {
  TERMMESH_RELOAD_TMP_ROOT="$SANDBOX" bash -c '
    set -euo pipefail
    STAGING_TMP_ROOT="'"$SANDBOX"'"
    '"$(sed -n '/^staging_socket_path()/,/^}/p' "$SCRIPT")"'
    staging_socket_path "$1"
  ' _ "$1"
}
check "tagged"        "$(probe_socket com.termmesh.app.staging.leakrel)" "$SANDBOX/term-mesh-staging-leakrel.sock"
check "dotted tag"    "$(probe_socket com.termmesh.app.staging.fix.blur)" "$SANDBOX/term-mesh-staging-fix-blur.sock"
check "bare staging"  "$(probe_socket com.termmesh.app.staging)"          "$SANDBOX/term-mesh-staging.sock"

echo
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
