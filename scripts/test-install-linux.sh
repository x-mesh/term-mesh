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
tar -czf "$out" -C "$stage" term-meshd
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

echo '==> installer scope simulations passed'
