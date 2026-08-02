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
  members="term-meshd tm-agent"
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
[[ "${1:-}" == -n ]] && shift
exec "$@"
EOF
chmod +x "$MOCK_BIN/systemctl" "$MOCK_BIN/curl" "$MOCK_BIN/loginctl" "$MOCK_BIN/sudo"

export PATH="$MOCK_BIN:$PATH" TERMMESH_INSTALL_TAG=vtest

echo '==> system install uses an unprivileged, hardened service'
bash "$INSTALLER"
grep -qx 'User=term-mesh' /etc/systemd/system/term-meshd.service
grep -qx 'Group=term-mesh' /etc/systemd/system/term-meshd.service
grep -qx 'NoNewPrivileges=true' /etc/systemd/system/term-meshd.service
grep -qx 'CapabilityBoundingSet=' /etc/systemd/system/term-meshd.service
grep -qx 'ProtectSystem=full' /etc/systemd/system/term-meshd.service
grep -qx 'ProtectHome=true' /etc/systemd/system/term-meshd.service
grep -qx 'RuntimeDirectory=term-mesh' /etc/systemd/system/term-meshd.service
grep -qx 'TERMMESH_PEER_SOCKET=/run/term-mesh/tm-peer.sock' /etc/term-mesh/peer.env
[[ $(id -u term-mesh) != 0 ]]

echo '==> system to user switch removes the old scope first'
useradd --create-home tester
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

echo '==> system service user must not be root'
if TERMMESH_SERVICE_USER=root TERMMESH_INSTALL_PREFIX=/opt/term-mesh-root \
  bash "$INSTALLER"; then
  echo 'expected root service user rejection' >&2
  exit 1
fi
[[ ! -e /opt/term-mesh-root/term-meshd ]]

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

echo '==> installer scope simulations passed'
