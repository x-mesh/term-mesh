# End-to-end fixture for the passwd login-shell fallback
# (term-meshd surface.rs: resolve_login_shell / passwd_login_shell).
#
# The whole point is a machine that reproduces the reported bug's shape:
#   - zsh is installed and is the account's /etc/passwd login shell (chsh),
#   - but the daemon inherits NO usable $SHELL (systemd / non-login SSH).
# On such a host the OLD code dropped to /bin/bash|/bin/sh; the fix reads
# zsh out of the passwd database via getpwuid_r instead.
FROM rust:slim

# zsh = the "configured" login shell we expect to resolve to.
#
# The rest is term-meshd's native build surface: rust:slim ships no C
# toolchain, so openssl-sys/libgit2-sys/libsqlite3-sys/libz-sys all fail to
# build without these. Installing the -dev packages (plus OPENSSL_NO_VENDOR
# below) also lets openssl-sys link the system OpenSSL instead of compiling
# a vendored copy from source, which is both slow and needs a fuller perl
# than perl-base (the `Can't locate FindBin.pm` failure).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      zsh ca-certificates \
      build-essential pkg-config cmake perl git \
      libssl-dev zlib1g-dev libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*

# Link the system OpenSSL even though a dependency enables the `vendored`
# feature — without this openssl-sys builds OpenSSL from source every time.
ENV OPENSSL_NO_VENDOR=1

# A non-root account whose passwd login shell is zsh — the `chsh -s zsh`
# equivalent, baked in at image build so the test needs no runtime setup.
RUN useradd --create-home --shell "$(command -v zsh)" tester

# Keep build artifacts off the read-only source mount.
ENV CARGO_TARGET_DIR=/tmp/target
WORKDIR /src
