#!/usr/bin/env bash
#
# zsh-login-shell-test/run.sh — end-to-end proof that term-meshd resolves a
# pane's login shell from /etc/passwd when the daemon inherited no $SHELL.
#
# Why a container: the fix (surface.rs passwd_login_shell / resolve_login_shell)
# calls the real getpwuid_r, so it can only be verified on a host whose account
# is chsh-ed to a known shell. This builds an image whose `tester` account has
# zsh as its passwd login shell, then runs the two `#[ignore]`d unit tests as
# `tester` with $SHELL stripped — the exact systemd / non-login-SSH shape.
#
# Usage:
#   daemon/scripts/zsh-login-shell-test/run.sh
#
# Requires: docker. First run compiles term-meshd's dep tree inside the
# container (slow); reruns reuse the image layer + a named cargo cache volume.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Mount the REPO ROOT, not just daemon/: peer-proto's build.rs compiles
# `../../proto/peer/v1/peer.proto`, which lives above the cargo workspace.
repo_root="$(cd "$here/../../.." && pwd)"
img="term-meshd-zsh-login-test"
cache_vol="term-meshd-zsh-login-cargo"    # persist registry + target across runs

echo "==> building image ($img)"
docker build -t "$img" "$here"

echo "==> running passwd-fallback e2e as user 'tester' (zsh login shell, SHELL unset)"
# Mount the repo read-only; cargo writes only to the cache volume (CARGO_HOME)
# and CARGO_TARGET_DIR, both outside the source tree.
docker run --rm \
  -v "$repo_root":/src:ro \
  -v "$cache_vol":/cargo \
  -e CARGO_HOME=/cargo \
  -e CARGO_TARGET_DIR=/cargo/target \
  "$img" \
  bash -euo pipefail -c '
    zsh_path="$(command -v zsh)"
    echo "container zsh:        $zsh_path"
    echo "tester passwd entry:  $(getent passwd tester)"
    # /cargo is the mounted volume — let tester own it for the build.
    chown -R tester /cargo
    # Run the ignored tests AS tester so getpwuid_r sees the zsh account, with
    # $SHELL removed so the passwd branch (not the $SHELL branch) is exercised.
    # `-s /bin/bash` forces bash for this su command regardless of the login
    # shell; `env -u SHELL` guarantees no inherited SHELL reaches cargo.
    su tester -s /bin/bash -c "
      cd /src/daemon &&
      env -u SHELL OPENSSL_NO_VENDOR=1 EXPECT_PASSWD_SHELL=$zsh_path \
        cargo test -p term-meshd --bins --locked -- \
          --ignored --nocapture login_shell
    "
  '

echo "==> OK — passwd login-shell fallback resolves zsh with SHELL unset"
