#!/usr/bin/env bash
# Behavioral tests for lib/cargo.sh and the daemon-build guard that uses it.
#
# Two things have to hold together, and neither is visible from `bash -n`:
# cargo has to be found when PATH does not list it (the non-interactive ssh
# case), and a cargo that IS found but fails has to stop the run rather than
# leave a stale term-meshd in the bundle.
#
# Run: ./scripts/test-cargo-resolve.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

make_cargo() {  # make_cargo <dir> <exit code>
  mkdir -p "$1"
  printf '#!/bin/sh\nexit %s\n' "$2" > "$1/cargo"
  chmod +x "$1/cargo"
}

# A PATH with none of the usual cargo locations on it, standing in for the
# environment `ssh host 'cmd'` hands you.
BARE_PATH="/usr/bin:/bin"

resolve() {  # resolve <HOME> <CARGO_HOME|-> <PATH> [candidates] -> "<rc>|<CARGO_BIN>|<on PATH?>"
  local home="$1" cargo_home="$2" path="$3" candidates="${4:-}"
  env -i HOME="$home" PATH="$path" TERMMESH_CARGO_CANDIDATES="$candidates" /bin/bash -c '
    set -uo pipefail
    if [ -n "${2:-}" ] && [ "$2" != "-" ]; then export CARGO_HOME="$2"; fi
    . "$1/lib/cargo.sh"
    if resolve_cargo; then rc=0; else rc=1; fi
    case ":$PATH:" in *":$(dirname "${CARGO_BIN:-/nonexistent}"):"*) on_path=yes ;; *) on_path=no ;; esac
    printf "%s|%s|%s" "$rc" "$CARGO_BIN" "$on_path"
  ' _ "$SCRIPT_DIR" "$cargo_home"
}

echo "== syntax =="
for f in lib/cargo.sh reload.sh reloads.sh; do
  if bash -n "$SCRIPT_DIR/$f"; then ok "$f parses"; else bad "$f parses"; fi
done

echo "== finds cargo already on PATH =="
H="$SANDBOX/h1"; make_cargo "$H/bin" 0
R="$(resolve "$H" - "$H/bin:$BARE_PATH")"
check "returns 0"        "${R%%|*}"            "0"
check "uses the PATH one" "$(echo "$R" | cut -d'|' -f2)" "$H/bin/cargo"

echo "== finds ~/.cargo/bin when PATH does not list it =="
H="$SANDBOX/h2"; make_cargo "$H/.cargo/bin" 0
R="$(resolve "$H" - "$BARE_PATH")"
check "returns 0"          "${R%%|*}"                      "0"
check "resolves the binary" "$(echo "$R" | cut -d'|' -f2)" "$H/.cargo/bin/cargo"
# rustc and cargo get shelled out to by name from build scripts, so knowing the
# path is not enough — the directory has to land on PATH as well.
check "puts it on PATH"     "$(echo "$R" | cut -d'|' -f3)" "yes"

echo "== honours CARGO_HOME =="
H="$SANDBOX/h3"; make_cargo "$SANDBOX/custom-cargo/bin" 0
R="$(resolve "$H" "$SANDBOX/custom-cargo" "$BARE_PATH")"
check "resolves via CARGO_HOME" "$(echo "$R" | cut -d'|' -f2)" "$SANDBOX/custom-cargo/bin/cargo"

echo "== reports absence instead of guessing =="
# Pin the search list at paths that cannot exist. Without this the assertion
# silently inverts on any machine that happens to have Homebrew's cargo — which
# is exactly how this test passed on one Mac and failed on another.
H="$SANDBOX/h4"; mkdir -p "$H"
R="$(resolve "$H" - "$BARE_PATH" "$SANDBOX/nope/cargo:$SANDBOX/also-nope/cargo")"
check "returns 1"       "${R%%|*}"                      "1"
check "CARGO_BIN empty" "$(echo "$R" | cut -d'|' -f2)"  ""

echo "== a failing daemon build stops the run =="
# Extracts each script's daemon-build block and drives it against a cargo stub
# that fails, so the guard is exercised without a full app build.
daemon_guard_rc() {  # daemon_guard_rc <script> <cargo exit code>
  local script="$1" code="$2"
  local work="$SANDBOX/guard-$(basename "$script" .sh)-$code"
  mkdir -p "$work/daemon" "$work/bin"
  : > "$work/daemon/Cargo.toml"
  make_cargo "$work/bin" "$code"
  local block
  block="$(sed -n '/^if \[\[ -d "\$PWD\/daemon" && -f "\$PWD\/daemon\/Cargo.toml" \]\]; then/,/^fi$/p' "$SCRIPT_DIR/$script")"
  if [[ -z "$block" ]]; then echo "NOBLOCK"; return; fi
  ( cd "$work" && env PATH="$work/bin:$BARE_PATH" SHARED_CARGO_TARGET="$work/target" \
      /bin/bash -c '
        set -uo pipefail
        . "$1/lib/cargo.sh"
        '"$block"'
      ' _ "$SCRIPT_DIR" >/dev/null 2>&1 )
  echo "$?"
}
check "reloads.sh: failing cargo is fatal" "$(daemon_guard_rc reloads.sh 1)" "1"
check "reloads.sh: passing cargo continues" "$(daemon_guard_rc reloads.sh 0)" "0"
check "reload.sh: failing cargo is fatal"  "$(daemon_guard_rc reload.sh 1)"  "1"
check "reload.sh: passing cargo continues" "$(daemon_guard_rc reload.sh 0)"  "0"

echo
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
