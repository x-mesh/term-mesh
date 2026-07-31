#!/usr/bin/env bash
# Install term-meshd as a systemd service on Linux.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/x-mesh/term-mesh/main/scripts/install-linux.sh | bash
#
# Service scope is chosen automatically: a per-user service (systemctl
# --user) when the user's systemd bus is reachable, otherwise a system
# service (/etc/systemd/system) when running as root. Hosts with no
# per-user bus — non-interactive ssh sessions, and older systemd such as
# RHEL/CentOS 7's 219 — take the root/system path; a non-root run there
# stops with instructions instead of half-installing.
#
# Re-running this script is safe: it replaces the binary and unit file,
# restarts the service, and leaves any existing peer.env config alone.
#
# Env overrides:
#   TERMMESH_INSTALL_TAG   Release tag to install (default: latest)
#   TERMMESH_INSTALL_REPO  GitHub repo to fetch from (default: x-mesh/term-mesh)
#   TERMMESH_INSTALL_PREFIX Install directory for the binary (default: ~/.local/bin)
#
# What this does NOT do: bind the peer socket to a fixed path chosen for
# you, or pick surfaces to expose. Those are yours to set in
# ~/.config/term-mesh/peer.env after install — see docs/peer-linux-host.md.
set -euo pipefail

REPO="${TERMMESH_INSTALL_REPO:-x-mesh/term-mesh}"
TAG="${TERMMESH_INSTALL_TAG:-latest}"
PREFIX="${TERMMESH_INSTALL_PREFIX:-$HOME/.local/bin}"
CONFIG_DIR="$HOME/.config/term-mesh"
UNIT_DIR="$HOME/.config/systemd/user"
BIN_NAME="term-meshd"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || die "this script installs a Linux systemd service; run it on a Linux host"
command -v systemctl >/dev/null 2>&1 || die "systemctl not found — this script requires systemd"
command -v curl >/dev/null 2>&1 || die "curl not found"
command -v tar >/dev/null 2>&1 || die "tar not found"

# Normalize uname -m to the arch suffix release-linux.yml publishes assets
# under (x86_64 / aarch64). Some distros report arm64 for the same thing.
case "$(uname -m)" in
  x86_64|amd64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) die "unsupported architecture: $(uname -m) (term-mesh publishes x86_64 and aarch64 only)" ;;
esac

if [[ "$TAG" == "latest" ]]; then
  # Resolve the redirect from /releases/latest rather than hitting the API
  # (no auth needed, no rate-limit-sensitive JSON parsing dependency).
  TAG=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest" | sed 's#.*/tag/##')
  [[ -n "$TAG" ]] || die "could not resolve the latest release tag for ${REPO}"
fi
log "installing ${REPO} ${TAG} (${ARCH})"

ASSET="term-meshd-linux-${ARCH}.tar.gz"
BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

log "downloading ${ASSET}"
curl -fsSL -o "${WORK_DIR}/${ASSET}" "${BASE_URL}/${ASSET}" \
  || die "download failed — does ${TAG} have a Linux ${ARCH} asset? https://github.com/${REPO}/releases/tag/${TAG}"

if curl -fsSL -o "${WORK_DIR}/${ASSET}.sha256" "${BASE_URL}/${ASSET}.sha256" 2>/dev/null; then
  log "verifying checksum"
  (cd "$WORK_DIR" && sha256sum -c "${ASSET}.sha256") \
    || die "checksum verification failed — the downloaded asset is corrupt or tampered"
else
  log "warning: no .sha256 asset published for this release; skipping checksum verification"
fi

log "extracting"
tar -xzf "${WORK_DIR}/${ASSET}" -C "$WORK_DIR"
[[ -f "${WORK_DIR}/${BIN_NAME}" ]] || die "archive did not contain a '${BIN_NAME}' binary"

mkdir -p "$PREFIX"
install -m 0755 "${WORK_DIR}/${BIN_NAME}" "${PREFIX}/${BIN_NAME}"
log "installed ${PREFIX}/${BIN_NAME}"

# Smoke-test the binary before wiring any service around it. `--version`
# exits before the daemon starts (main.rs), but the dynamic linker runs
# first — so a glibc-too-old host fails here with the exact "GLIBC_x.y
# not found" it would fail with at service start. Catching it now means a
# clear message instead of a service that flaps in the background.
if ! smoke_out=$("${PREFIX}/${BIN_NAME}" --version 2>&1); then
  die "the installed ${BIN_NAME} cannot run on this host:

  ${smoke_out}

This is almost always a glibc that is too old: the release binary is
built against a glibc 2.17 floor (RHEL/CentOS 7 and newer). Check this
host with 'ldd --version'. If it is older than 2.17 there is no
supported binary for it yet; on a supported host re-run this installer."
fi
log "binary runs: ${smoke_out}"

case ":$PATH:" in
  *":${PREFIX}:"*) ;;
  *) log "note: ${PREFIX} is not on your PATH — add 'export PATH=\"${PREFIX}:\$PATH\"' to your shell profile if you want to run term-meshd directly" ;;
esac

# Decide the service scope BEFORE writing config, because the default
# socket path differs between the two. `systemctl --user` needs a
# per-user systemd instance plus a session D-Bus ($XDG_RUNTIME_DIR/bus);
# non-interactive ssh sessions and old systemd (RHEL/CentOS 7's 219)
# often have neither, which used to abort daemon-reload with "Failed to
# get D-Bus connection" AFTER the binary and unit were already written.
# `show-environment` is a read-only probe that fails the same way, so it
# tells us up front which scope is actually usable.
if systemctl --user show-environment >/dev/null 2>&1; then
  SERVICE_SCOPE=user
  UNIT_PATH="${UNIT_DIR}/${BIN_NAME}.service"
  WANTED_BY=default.target
  PEER_SOCKET_DEFAULT="/run/user/$(id -u)/tm-peer.sock"
  RUNTIME_DIR_LINE=""
  systemctl_scoped() { systemctl --user "$@"; }
elif [[ "$(id -u)" == "0" ]]; then
  SERVICE_SCOPE=system
  UNIT_DIR="/etc/systemd/system"
  UNIT_PATH="${UNIT_DIR}/${BIN_NAME}.service"
  WANTED_BY=multi-user.target
  # A system service has no /run/user/<uid> (that is a login-session dir),
  # so bind under a RuntimeDirectory systemd creates and owns instead.
  PEER_SOCKET_DEFAULT="/run/term-mesh/tm-peer.sock"
  RUNTIME_DIR_LINE="RuntimeDirectory=term-mesh"
  systemctl_scoped() { systemctl "$@"; }
  log "user systemd bus unreachable — installing a system service (running as root)"
else
  die "cannot reach your user systemd bus, so 'systemctl --user' will not work here.
This host has no per-user systemd session — common over non-interactive
ssh, and on older systemd (e.g. RHEL/CentOS 7). Either:
  • re-run this installer as root, so it installs a system-wide service, or
  • start a lingering login session first:
        loginctl enable-linger $(whoami)
    then reconnect and re-run, so the --user bus exists."
fi

mkdir -p "$CONFIG_DIR"
ENV_FILE="${CONFIG_DIR}/peer.env"
if [[ ! -f "$ENV_FILE" ]]; then
  log "writing default config to ${ENV_FILE}"
  cat > "$ENV_FILE" <<EOF
# term-meshd peer-host config, loaded by ${UNIT_PATH}.
# Edit this file, then restart the service (see the install output below).

# Required for the peer server to start at all (opt-in — see main.rs).
TERMMESH_PEER_SOCKET=${PEER_SOCKET_DEFAULT}

# One "name=command" pair per line. Omit this entirely for a single
# default "\$SHELL -l" surface named "shell". Example:
# TERMMESH_PEER_SURFACES=shell=/bin/bash -l
# logs=journalctl -f
EOF
else
  log "keeping existing config at ${ENV_FILE}"
  # A config left over from a different scope can point the socket somewhere
  # this service can't bind — most often a /run/user/<uid> path inherited by
  # a now-system service, where that dir does not exist. Warn loudly rather
  # than silently rewriting the user's surfaces/socket choices.
  if [[ "$SERVICE_SCOPE" == system ]]; then
    existing_sock=$(sed -n 's/^TERMMESH_PEER_SOCKET=//p' "$ENV_FILE" | tail -n 1 | tr -d '"'"'"' ')
    if [[ "$existing_sock" == /run/user/* ]]; then
      log "warning: ${ENV_FILE} sets TERMMESH_PEER_SOCKET=${existing_sock}, which a"
      log "         system service cannot create. Edit it to ${PEER_SOCKET_DEFAULT}"
      log "         (and keep RuntimeDirectory=term-mesh in the unit), then restart."
    fi
  fi
fi

mkdir -p "$UNIT_DIR"
cat > "$UNIT_PATH" <<EOF
[Unit]
Description=term-mesh peer host
After=network.target

[Service]
EnvironmentFile=-${ENV_FILE}
ExecStart=${PREFIX}/${BIN_NAME}
${RUNTIME_DIR_LINE}
Restart=always
RestartSec=2

[Install]
WantedBy=${WANTED_BY}
EOF
log "wrote ${UNIT_PATH}"

systemctl_scoped daemon-reload
systemctl_scoped enable "${BIN_NAME}.service" >/dev/null
# `restart` (not start) so a re-run always picks up the just-installed
# binary; on a stopped/first-install unit it simply starts it.
systemctl_scoped restart "${BIN_NAME}.service"
log "started ${BIN_NAME}.service"

# Lingering only applies to a --user service: it keeps the user's systemd
# instance (and this service) alive across logout / before any interactive
# login after boot. A system service already starts at boot via
# WantedBy=multi-user.target, so this step is skipped there.
if [[ "$SERVICE_SCOPE" == user ]]; then
  if loginctl enable-linger "$(whoami)" 2>/dev/null; then
    log "enabled lingering for $(whoami) (service survives logout and reboot)"
  else
    log "warning: could not enable lingering (loginctl enable-linger $(whoami)) — the service will stop when you log out. Run that command with sudo, or as root, to fix."
  fi
fi

echo
log "done. Useful commands:"
if [[ "$SERVICE_SCOPE" == user ]]; then
  echo "    systemctl --user status ${BIN_NAME}"
  echo "    journalctl --user -u ${BIN_NAME} -f"
  echo "    \$EDITOR ${ENV_FILE}   # then: systemctl --user restart ${BIN_NAME}"
else
  echo "    systemctl status ${BIN_NAME}"
  echo "    journalctl -u ${BIN_NAME} -f"
  echo "    \$EDITOR ${ENV_FILE}   # then: systemctl restart ${BIN_NAME}"
fi
