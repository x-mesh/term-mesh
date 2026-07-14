#!/usr/bin/env bash
# Install term-meshd as a systemd --user service on Linux.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/x-mesh/term-mesh/main/scripts/install-linux.sh | bash
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

RESTART_NEEDED=false
if systemctl --user is-active --quiet "${BIN_NAME}.service" 2>/dev/null; then
  RESTART_NEEDED=true
fi

mkdir -p "$PREFIX"
install -m 0755 "${WORK_DIR}/${BIN_NAME}" "${PREFIX}/${BIN_NAME}"
log "installed ${PREFIX}/${BIN_NAME}"

case ":$PATH:" in
  *":${PREFIX}:"*) ;;
  *) log "note: ${PREFIX} is not on your PATH — add 'export PATH=\"${PREFIX}:\$PATH\"' to your shell profile if you want to run term-meshd directly" ;;
esac

mkdir -p "$CONFIG_DIR"
ENV_FILE="${CONFIG_DIR}/peer.env"
if [[ ! -f "$ENV_FILE" ]]; then
  log "writing default config to ${ENV_FILE}"
  cat > "$ENV_FILE" <<EOF
# term-meshd peer-host config, loaded by ~/.config/systemd/user/term-meshd.service.
# Edit this file, then: systemctl --user restart term-meshd

# Required for the peer server to start at all (opt-in — see main.rs).
TERMMESH_PEER_SOCKET=/run/user/$(id -u)/tm-peer.sock

# One "name=command" pair per line. Omit this entirely for a single
# default "\$SHELL -l" surface named "shell". Example:
# TERMMESH_PEER_SURFACES=shell=/bin/bash -l
# logs=journalctl -f
EOF
else
  log "keeping existing config at ${ENV_FILE}"
fi

mkdir -p "$UNIT_DIR"
cat > "${UNIT_DIR}/${BIN_NAME}.service" <<EOF
[Unit]
Description=term-mesh peer host
After=network.target

[Service]
EnvironmentFile=-${ENV_FILE}
ExecStart=${PREFIX}/${BIN_NAME}
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF
log "wrote ${UNIT_DIR}/${BIN_NAME}.service"

systemctl --user daemon-reload
systemctl --user enable "${BIN_NAME}.service" >/dev/null
if [[ "$RESTART_NEEDED" == true ]]; then
  systemctl --user restart "${BIN_NAME}.service"
  log "restarted ${BIN_NAME}.service (was already running)"
else
  systemctl --user start "${BIN_NAME}.service"
  log "started ${BIN_NAME}.service"
fi

# Lingering keeps the user's systemd instance (and this service) running
# across logout / before any interactive login after boot. Without it,
# the service dies the moment the installing SSH session ends. Failure
# here is a warning, not fatal — some minimal/containerized hosts restrict
# loginctl and the service still runs fine for the current session.
if loginctl enable-linger "$(whoami)" 2>/dev/null; then
  log "enabled lingering for $(whoami) (service survives logout and reboot)"
else
  log "warning: could not enable lingering (loginctl enable-linger $(whoami)) — the service will stop when you log out. Run that command with sudo, or as root, to fix."
fi

echo
log "done. Useful commands:"
echo "    systemctl --user status ${BIN_NAME}"
echo "    journalctl --user -u ${BIN_NAME} -f"
echo "    \$EDITOR ${ENV_FILE}   # then: systemctl --user restart ${BIN_NAME}"
