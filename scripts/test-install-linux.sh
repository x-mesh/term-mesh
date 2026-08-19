#!/usr/bin/env bash
# Focused, destructive-only-inside-the-container test for install-linux.sh.
# Run via the Docker command documented in this task's verification report.
set -euo pipefail

INSTALLER=${1:-/repo/scripts/install-linux.sh}
MOCK_BIN=/tmp/term-mesh-installer-mocks
CALLS=/tmp/term-mesh-installer-calls
mkdir -p "$MOCK_BIN"
: > "$CALLS"
chmod 0666 "$CALLS"

cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> /tmp/term-mesh-installer-calls
if [[ "$*" == "--user show-environment" ]]; then
  [[ "${MOCK_USER_BUS:-0}" == 1 ]]
elif [[ "$*" == "disable --now term-meshd.service" ]]; then
  [[ "${MOCK_FAIL_SYSTEM_CLEANUP:-0}" != 1 ]]
elif [[ "$*" == "--user disable --now term-meshd.service" ]]; then
  [[ "${MOCK_FAIL_USER_CLEANUP:-0}" != 1 ]]
fi
EOF
cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do
  if [[ "$1" == -o ]]; then out=$2; shift 2; else shift; fi
done
[[ -n "$out" ]] || exit 2
if [[ "$out" == *.sha256 ]]; then exit 22; fi
stage=$(mktemp -d)
cat > "$stage/term-meshd" <<'BIN'
#!/usr/bin/env bash
echo 'term-meshd test'
BIN
chmod +x "$stage/term-meshd"
members=term-meshd
# MOCK_ARCHIVE_HAS_CLI=0 reproduces a pre-0.170.2 asset, which carried only
# the daemon. The installer has to keep working against those.
if [[ "${MOCK_ARCHIVE_HAS_CLI:-1}" == 1 ]]; then
  cat > "$stage/tm-agent" <<'BIN'
#!/usr/bin/env bash
echo 'tm-agent test'
BIN
  chmod +x "$stage/tm-agent"
  members="$members tm-agent"
fi
# MOCK_ARCHIVE_HAS_BRIDGE=0 reproduces an asset from before the bridge shipped.
# The bridge is optional: its absence warns, never fails.
if [[ "${MOCK_ARCHIVE_HAS_BRIDGE:-1}" == 1 ]]; then
  cat > "$stage/tm-agent-bridge" <<'BIN'
#!/usr/bin/env bash
echo 'tm-agent-bridge test'
BIN
  chmod +x "$stage/tm-agent-bridge"
  members="$members tm-agent-bridge"
fi
tar -czf "$out" -C "$stage" $members
rm -rf "$stage"
EOF
cat > "$MOCK_BIN/loginctl" <<'EOF'
#!/usr/bin/env bash
printf 'loginctl %s\n' "$*" >> /tmp/term-mesh-installer-calls
EOF
cat > "$MOCK_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> /tmp/term-mesh-installer-calls
[[ "${1:-}" == -n ]] && shift
exec "$@"
EOF
chmod +x "$MOCK_BIN/systemctl" "$MOCK_BIN/curl" "$MOCK_BIN/loginctl" "$MOCK_BIN/sudo"

export PATH="$MOCK_BIN:$PATH" TERMMESH_INSTALL_TAG=vtest

TERMMESH_INSTALL_LIB_ONLY=1 source "$INSTALLER"
[[ "$(resolve_connecting_user 0 root tester '')" == root ]]
[[ "$(resolve_connecting_user 0 root tester 1000)" == tester ]]
[[ "$(resolve_connecting_user 0 root root 0)" == root ]]
[[ "$(resolve_connecting_user 1000 tester '' '')" == tester ]]
# ProtectHome is decided by the home directory, because that is what it hides.
[[ "$(resolve_protect_home /var/lib/term-mesh)" == true ]]
[[ "$(resolve_protect_home /home/tester)" == false ]]
[[ "$(resolve_protect_home /home)" == false ]]
[[ "$(resolve_protect_home /root)" == false ]]
[[ "$(resolve_protect_home /run/user/1000)" == false ]]
[[ "$(resolve_protect_home /srv/term-mesh)" == true ]]
unset TERMMESH_INSTALL_LIB_ONLY

echo '==> system install follows the connecting account and stays hardened'
bash "$INSTALLER"
grep -qx 'User=root' /etc/systemd/system/term-meshd.service
grep -qx 'Group=root' /etc/systemd/system/term-meshd.service
grep -qx 'NoNewPrivileges=true' /etc/systemd/system/term-meshd.service
grep -qx 'CapabilityBoundingSet=' /etc/systemd/system/term-meshd.service
grep -qx 'ProtectSystem=full' /etc/systemd/system/term-meshd.service
grep -qx 'ProtectHome=false' /etc/systemd/system/term-meshd.service
grep -qx 'RuntimeDirectory=term-mesh' /etc/systemd/system/term-meshd.service
grep -qx 'TERMMESH_PEER_SOCKET=/run/term-mesh/tm-peer.sock' /etc/term-mesh/peer.env
grep -qx 'TERMMESH_DAEMON_UNIX_PATH=/run/term-mesh/term-meshd.sock' /etc/term-mesh/peer.env
if grep -q '^sudo ' "$CALLS"; then
  echo 'direct root install must not invoke sudo' >&2
  exit 1
fi

echo '==> an old system config gains the reachable control socket on upgrade'
sed -i '/^TERMMESH_DAEMON_UNIX_PATH=/d' /etc/term-mesh/peer.env
printf '%s\n' 'TERMMESH_DAEMON_UNIX_PATH=/tmp/overridden.sock' >> /etc/term-mesh/peer.env
printf '%s\n' 'TERMMESH_DAEMON_UNIX_PATH=' >> /etc/term-mesh/peer.env
TERMMESH_INSTALL_PREFIX=/opt/term-mesh-upgrade bash "$INSTALLER"
grep -qx 'TERMMESH_DAEMON_UNIX_PATH=/run/term-mesh/term-meshd.sock' /etc/term-mesh/peer.env
[[ "$(grep -c '^TERMMESH_DAEMON_UNIX_PATH=' /etc/term-mesh/peer.env)" == 1 ]]

echo '==> an explicit control socket choice survives reinstall'
sed -i 's#^TERMMESH_DAEMON_UNIX_PATH=.*#TERMMESH_DAEMON_UNIX_PATH=/srv/term-mesh/control.sock#' \
  /etc/term-mesh/peer.env
TERMMESH_INSTALL_PREFIX=/opt/term-mesh-explicit bash "$INSTALLER"
grep -qx 'TERMMESH_DAEMON_UNIX_PATH=/srv/term-mesh/control.sock' /etc/term-mesh/peer.env
[[ "$(grep -c '^TERMMESH_DAEMON_UNIX_PATH=' /etc/term-mesh/peer.env)" == 1 ]]

echo '==> sudo system install follows the invoking SSH account'
useradd --create-home tester
SUDO_USER=tester SUDO_UID=$(id -u tester) \
  TERMMESH_INSTALL_PREFIX=/opt/term-mesh-sudo-user bash "$INSTALLER"
grep -qx 'User=tester' /etc/systemd/system/term-meshd.service
grep -qx 'Group=tester' /etc/systemd/system/term-meshd.service
grep -qx 'Environment=HOME=/home/tester' /etc/systemd/system/term-meshd.service
grep -qx 'ProtectHome=false' /etc/systemd/system/term-meshd.service

echo '==> a dedicated account created here lives outside /home and stays hardened'
TERMMESH_SERVICE_USER=term-mesh TERMMESH_INSTALL_PREFIX=/opt/term-mesh-dedicated \
  bash "$INSTALLER"
grep -qx 'User=term-mesh' /etc/systemd/system/term-meshd.service
grep -qx 'Environment=HOME=/var/lib/term-mesh' /etc/systemd/system/term-meshd.service
grep -qx 'ProtectHome=true' /etc/systemd/system/term-meshd.service

echo '==> a dedicated account that already lives under /home is not hidden from itself'
TERMMESH_SERVICE_USER=tester TERMMESH_INSTALL_PREFIX=/opt/term-mesh-existing \
  bash "$INSTALLER"
grep -qx 'User=tester' /etc/systemd/system/term-meshd.service
grep -qx 'Environment=HOME=/home/tester' /etc/systemd/system/term-meshd.service
grep -qx 'ProtectHome=false' /etc/systemd/system/term-meshd.service

echo '==> system to user switch removes the old scope first'
chmod 0777 /etc/systemd/system
if runuser -u tester -- env HOME=/home/tester PATH="$PATH" \
  MOCK_USER_BUS=1 MOCK_FAIL_SYSTEM_CLEANUP=1 TERMMESH_INSTALL_TAG=vtest \
  bash "$INSTALLER"; then
  echo 'expected system cleanup failure' >&2
  exit 1
fi
[[ -e /etc/systemd/system/term-meshd.service ]]
[[ ! -e /home/tester/.local/bin/term-meshd ]]
runuser -u tester -- env HOME=/home/tester PATH="$PATH" \
  MOCK_USER_BUS=1 TERMMESH_INSTALL_TAG=vtest bash "$INSTALLER"
[[ ! -e /etc/systemd/system/term-meshd.service ]]
grep -qx 'ExecStart=/home/tester/.local/bin/term-meshd' \
  /home/tester/.config/systemd/user/term-meshd.service
tester_uid=$(id -u tester)
grep -qx "TERMMESH_PEER_SOCKET=/run/user/${tester_uid}/tm-peer.sock" \
  /home/tester/.config/term-mesh/peer.env
grep -qx "TERMMESH_DAEMON_UNIX_PATH=/run/user/${tester_uid}/term-meshd.sock" \
  /home/tester/.config/term-mesh/peer.env
grep -q 'systemctl disable --now term-meshd.service' "$CALLS"

echo '==> user to system switch fails closed when the user bus is unavailable'
mkdir -p /root/.config/systemd/user
touch /root/.config/systemd/user/term-meshd.service
if MOCK_FAIL_USER_CLEANUP=1 TERMMESH_INSTALL_PREFIX=/opt/term-mesh-fail \
  bash "$INSTALLER"; then
  echo 'expected cleanup failure' >&2
  exit 1
fi
[[ -e /root/.config/systemd/user/term-meshd.service ]]
[[ ! -e /opt/term-mesh-fail/term-meshd ]]

echo '==> user to system switch removes the old scope on success'
TERMMESH_INSTALL_PREFIX=/opt/term-mesh-switch bash "$INSTALLER"
[[ ! -e /root/.config/systemd/user/term-meshd.service ]]
grep -qx 'ExecStart=/opt/term-mesh-switch/term-meshd' \
  /etc/systemd/system/term-meshd.service

echo '==> an explicit service account remains available'
TERMMESH_SERVICE_USER=term-mesh TERMMESH_INSTALL_PREFIX=/opt/term-mesh-service \
  bash "$INSTALLER"
grep -qx 'User=term-mesh' /etc/systemd/system/term-meshd.service
grep -qx 'Group=term-mesh' /etc/systemd/system/term-meshd.service
grep -qx 'ProtectHome=true' /etc/systemd/system/term-meshd.service

# The CLI is why the fleet drifted: the asset carried only the daemon, so
# nothing on a Linux host could ever update tm-agent and every peer sat
# versions behind while its daemon tracked releases.
echo '==> the CLI ships and installs beside the daemon'
TERMMESH_INSTALL_PREFIX=/opt/term-mesh-cli bash "$INSTALLER" > /tmp/cli-install.log 2>&1
[[ -x /opt/term-mesh-cli/tm-agent ]] || { echo 'tm-agent was not installed' >&2; exit 1; }
[[ "$(/opt/term-mesh-cli/tm-agent --version)" == 'tm-agent test' ]]
grep -q 'installed /opt/term-mesh-cli/tm-agent' /tmp/cli-install.log

# The copy that wins lives in a directory term-mesh searches, which is NOT
# the same as a directory on this script's PATH. Installing 0.170.2 onto two
# peers left both running the 0.170.1 copies in ~/.local/bin precisely
# because the first version of this check only consulted $PATH — and root's
# PATH has no ~/.local/bin, so it saw nothing. $PATH stays deliberately
# clean here: the warning has to fire anyway.
echo '==> a stale CLI in a term-mesh search dir is named even when it is off $PATH'
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/tm-agent" <<'SH'
#!/usr/bin/env bash
echo 'tm-agent 0.0.1-stale'
SH
chmod +x "$HOME/.local/bin/tm-agent"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) echo 'fixture invalid: ~/.local/bin must not be on PATH' >&2; exit 1 ;;
esac
TERMMESH_INSTALL_PREFIX=/opt/term-mesh-cli bash "$INSTALLER" > /tmp/shadow-install.log 2>&1
grep -q "$HOME/.local/bin/tm-agent" /tmp/shadow-install.log \
  || { echo 'the shadowing copy was not reported' >&2; exit 1; }
grep -q '0.0.1-stale' /tmp/shadow-install.log
grep -q 'term-mesh will run' /tmp/shadow-install.log \
  || { echo 'the warning must say which binary actually runs' >&2; exit 1; }
rm -f "$HOME/.local/bin/tm-agent"

# An older tag's archive holds no tm-agent. Installing one must still work.
echo '==> an archive without the CLI still installs the daemon'
MOCK_ARCHIVE_HAS_CLI=0 TERMMESH_INSTALL_PREFIX=/opt/term-mesh-nocli \
  bash "$INSTALLER" > /tmp/nocli-install.log 2>&1
[[ -x /opt/term-mesh-nocli/term-meshd ]]
[[ ! -e /opt/term-mesh-nocli/tm-agent ]]
grep -q 'carries no tm-agent' /tmp/nocli-install.log

# The bridge rides the same asset so a Linux peer can hold native codex/kiro
# agents. It has no --version (pipe-only), so presence and mode are the checks.
echo '==> the bridge ships and installs beside the daemon'
TERMMESH_INSTALL_PREFIX=/opt/term-mesh-bridge bash "$INSTALLER" > /tmp/bridge-install.log 2>&1
[[ -x /opt/term-mesh-bridge/tm-agent-bridge ]] || { echo 'tm-agent-bridge was not installed' >&2; exit 1; }
grep -q 'installed /opt/term-mesh-bridge/tm-agent-bridge' /tmp/bridge-install.log

# An archive from before the bridge shipped must warn, not fail — peers on
# older tags keep updating their daemon either way.
echo '==> an archive without the bridge still installs the daemon'
MOCK_ARCHIVE_HAS_BRIDGE=0 TERMMESH_INSTALL_PREFIX=/opt/term-mesh-nobridge \
  bash "$INSTALLER" > /tmp/nobridge-install.log 2>&1
[[ -x /opt/term-mesh-nobridge/term-meshd ]]
[[ ! -e /opt/term-mesh-nobridge/tm-agent-bridge ]]
grep -q 'carries no tm-agent-bridge' /tmp/nobridge-install.log

echo '==> installer scope simulations passed'
