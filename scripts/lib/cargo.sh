#!/usr/bin/env bash
# Shared cargo lookup for the build scripts.
#
# rustup installs cargo into ~/.cargo/bin and adds that directory to PATH from
# the shell profile. A non-interactive `ssh host 'cmd'` never reads a profile,
# so `command -v cargo` fails on a machine where cargo is plainly installed and
# works fine from a login shell.
#
# 2026-08-05 is the worked example: `ssh mac-sub './scripts/reloads.sh --tag x'`
# printed "cargo: command not found", carried on, and launched a Release app
# carrying whichever term-meshd happened to be in daemon/target/release — a
# binary no one in that run had built. The build looked like it succeeded.
#
# Finding cargo is only half of it. Build scripts and proc-macro crates shell
# out to `rustc` and `cargo` by name, so the directory has to go on PATH too,
# not just be recorded in a variable.
#
# Sets CARGO_BIN to an executable cargo and returns 0, or returns 1 when the
# machine genuinely has none — which callers should treat as their own kind of
# problem rather than as a reason to ship a stale binary.

resolve_cargo() {
  CARGO_BIN=""
  if command -v cargo >/dev/null 2>&1; then
    CARGO_BIN="$(command -v cargo)"
    return 0
  fi

  local candidate
  for candidate in \
    "${CARGO_HOME:-$HOME/.cargo}/bin/cargo" \
    "$HOME/.cargo/bin/cargo" \
    /opt/homebrew/bin/cargo \
    /usr/local/bin/cargo
  do
    if [[ -x "$candidate" ]]; then
      CARGO_BIN="$candidate"
      PATH="$(dirname "$candidate"):$PATH"
      export PATH
      return 0
    fi
  done

  return 1
}
