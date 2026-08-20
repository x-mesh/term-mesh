#!/usr/bin/env bash
set -euo pipefail

# This runner kills any running term-mesh instances while it exercises the app.
# Keep it guarded to known test hosts/users so it is not run accidentally on a
# daily-driver session. Override with TERMMESH_E2E_ALLOWED_USERS/HOSTS when
# provisioning a new runner.
csv_contains() {
  local csv="$1"
  local needle="$2"
  local item
  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

CURRENT_USER="$(id -un)"
CURRENT_HOST="$(hostname 2>/dev/null || true)"
CURRENT_HOST_SHORT="$(hostname -s 2>/dev/null || printf '%s' "$CURRENT_HOST")"
ALLOWED_USERS="${TERMMESH_E2E_ALLOWED_USERS:-term-mesh}"
ALLOWED_HOSTS="${TERMMESH_E2E_ALLOWED_HOSTS:-term-mesh-vm,mac-sub,jinwooui-MacBookPro,jinwooui-MacBookPro.local}"

if ! csv_contains "$ALLOWED_USERS" "$CURRENT_USER" \
  && ! csv_contains "$ALLOWED_HOSTS" "$CURRENT_HOST" \
  && ! csv_contains "$ALLOWED_HOSTS" "$CURRENT_HOST_SHORT"; then
  echo "ERROR: E2E runner is not enabled for this user/host." >&2
  echo "Current: user=$CURRENT_USER host=$CURRENT_HOST short=$CURRENT_HOST_SHORT" >&2
  echo "Allowed users: $ALLOWED_USERS" >&2
  echo "Allowed hosts: $ALLOWED_HOSTS" >&2
  echo "Run via: ssh mac-sub 'cd /Users/jinwoo/work/term-mesh && ./scripts/run-tests-v1.sh'" >&2
  echo "Or set TERMMESH_E2E_ALLOWED_HOSTS/USERS explicitly for a dedicated runner." >&2
  exit 2
fi

cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rust/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/term-mesh-tests-v1"
APP="$DERIVED_DATA_PATH/Build/Products/Debug/term-mesh DEV.app"
CLI="$DERIVED_DATA_PATH/Build/Products/Debug/term-mesh"
DAEMON_BIN="$PWD/daemon/target/release/term-meshd"
DAEMON_SOCK_PATH="${TMPDIR:-/tmp}/term-meshd.sock"
DAEMON_LOG_PATH="/tmp/term-meshd-v1-e2e.log"

echo "== build =="
./scripts/generate-build-info.sh
command -v cargo >/dev/null 2>&1 || { echo "ERROR: cargo not found" >&2; exit 1; }
(cd daemon && cargo build --release)
# Work around stale explicit-module cache artifacts (notably Sentry headers) that can
# intermittently break incremental VM builds with "file ... has been modified since the
# module file ... was built".
rm -rf "$DERIVED_DATA_PATH/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules" || true
xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme term-mesh \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build >/dev/null
xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme term-mesh-cli \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build >/dev/null

if [ ! -d "$APP" ]; then
  echo "ERROR: term-mesh DEV.app not found at expected path: $APP" >&2
  exit 1
fi
if [ ! -x "$CLI" ]; then
  echo "ERROR: term-mesh CLI not found at expected path: $CLI" >&2
  exit 1
fi
export TERMMESH_CLI="$CLI"
export TERMMESH_CLI_BIN="$CLI"

cleanup() {
  pkill -x "term-mesh DEV" || true
  pkill -x "term-mesh" || true
  pkill -f "term-meshd" || true
  rm -f /tmp/term-mesh*.sock /tmp/term-meshd*.sock || true
}

launch_and_wait() {
  cleanup
  # Wait briefly for the previous instance to fully terminate; LaunchServices can flake if we
  # relaunch too quickly.
  for _ in {1..50}; do
    pgrep -x "term-mesh DEV" >/dev/null 2>&1 || break
    sleep 0.1
  done

  # Force socket mode for deterministic automation runs, independent of prior user settings.
  defaults write com.termmesh.app.debug socketControlMode -string full >/dev/null 2>&1 || true

  TERMMESH_DAEMON_UNIX_PATH="$DAEMON_SOCK_PATH" \
  TERM_MESH_HTTP_DISABLED=1 \
  "$DAEMON_BIN" >>"$DAEMON_LOG_PATH" 2>&1 &

  # Launch directly with UI test mode enabled so startup follows deterministic test codepaths.
  DAEMON_BINARY_PATH="$DAEMON_BIN" \
  TERMMESH_DAEMON_UNIX_PATH="$DAEMON_SOCK_PATH" \
  TERMMESH_UI_TEST_MODE=1 \
  "$APP/Contents/MacOS/term-mesh DEV" >/dev/null 2>&1 &

  SOCK=""
  for _ in {1..120}; do
    SOCK=$(ls -t /tmp/term-mesh-debug*.sock /tmp/term-mesh*.sock /tmp/term-mesh-debug*.sock /tmp/term-mesh*.sock 2>/dev/null | head -1 || true)
    if [ -n "$SOCK" ] && [ -S "$SOCK" ]; then
      break
    fi
    sleep 0.25
  done

  if [ -z "$SOCK" ] || [ ! -S "$SOCK" ]; then
    echo "ERROR: Socket not ready (looked for /tmp/term-mesh*.sock)" >&2
    exit 1
  fi
  export TERMMESH_SOCKET_PATH="$SOCK"
  export TERMMESH_SOCKET="$SOCK"
  export TERMMESH_DAEMON_SOCKET="$DAEMON_SOCK_PATH"
  export TERMMESH_DAEMON_UNIX_PATH="$DAEMON_SOCK_PATH"

  for _ in {1..80}; do
    if [ -S "$DAEMON_SOCK_PATH" ]; then
      break
    fi
    sleep 0.1
  done
  if [ ! -S "$DAEMON_SOCK_PATH" ]; then
    echo "ERROR: daemon socket not ready: $DAEMON_SOCK_PATH" >&2
    exit 1
  fi

  # Ensure LaunchServices has a visible/main window attached for rendering checks.
  open "$APP" >/dev/null 2>&1 || true
  sleep 0.5

  echo "== wait ready =="
  python3 - <<'PY'
import time
import os
import sys

sys.path.insert(0, os.path.join(os.getcwd(), "tests"))
from termmesh import termmesh  # type: ignore

deadline = time.time() + 30.0
last = None
client = None
while time.time() < deadline:
    try:
        client = termmesh()
        client.connect()
        break
    except Exception as e:
        last = e
        time.sleep(0.1)
else:
    raise SystemExit(f"ERROR: Socket path exists but connect keeps failing: {last}")

workspace_ready = False
while time.time() < deadline:
    try:
        _ = client.current_workspace()
        # Many focus-sensitive tests require the main window to be key.
        # `open "$APP"` does not reliably activate the app when launched from SSH.
        try:
            client.activate_app()
        except Exception:
            pass
        workspace_ready = True
        break
    except Exception as e:
        last = e
        time.sleep(0.1)

if not workspace_ready:
    print(f"WARN: continuing without workspace-ready state: {last}")

# Use a fresh connection to avoid stale-listener races where the first connection succeeds but
# immediate reconnects fail with ECONNREFUSED.
probe_deadline = time.time() + 10.0
while time.time() < probe_deadline:
    probe = None
    try:
        probe = termmesh()
        probe.connect()
        if not probe.ping():
            raise RuntimeError("ping returned false")
        print("ready")
        break
    except Exception as e:
        last = e
        time.sleep(0.1)
    finally:
        if probe is not None:
            try:
                probe.close()
            except Exception:
                pass
else:
    raise SystemExit(f"ERROR: Ready-check reconnect/ping failed: {last}")

# Force a single fresh workspace so startup-state restoration doesn't leave tests
# focused on non-terminal panels (which breaks read_screen/read_terminal_text assumptions)
# or with extra pre-existing workspaces that make ordering-dependent tests flaky.
bootstrap_last = None
for _ in range(3):
    try:
        if client is not None:
            try:
                client.close()
            except Exception:
                pass
        client = termmesh()
        client.connect()

        existing_ids = []
        try:
            existing_ids = [row[1] for row in client.list_workspaces() if len(row) >= 2]
        except Exception:
            existing_ids = []

        ws_id = client.new_workspace()
        client.select_workspace(ws_id)

        for old_id in existing_ids:
            if old_id == ws_id:
                continue
            try:
                client.close_workspace(old_id)
            except Exception:
                pass

        surfaces = client.list_surfaces()
        if not surfaces:
            raise RuntimeError("new workspace has no surfaces")
        client.focus_surface(0)
        break
    except Exception as e:
        bootstrap_last = e
        time.sleep(0.2)
else:
    raise SystemExit(f"ERROR: Failed to bootstrap fresh terminal workspace: {bootstrap_last}")

window_last = None
window_deadline = time.time() + 10.0
while time.time() < window_deadline:
    try:
        health = client.surface_health()
        if any(bool(row.get("in_window")) for row in health):
            break
        client.activate_app()
    except Exception as e:
        window_last = e
    time.sleep(0.1)
else:
    print(f"WARN: no in-window terminal surface detected before test start: {window_last}")

if client is not None:
    try:
        client.close()
    except Exception:
        pass
PY
}

run_test_with_retry() {
  local f="$1"
  local attempts=3
  local n=1

  while [ "$n" -le "$attempts" ]; do
    echo "RUN  $f (attempt $n/$attempts)"
    if python3 "$f"; then
      return 0
    fi

    if [ "$n" -ge "$attempts" ]; then
      return 1
    fi

    echo "WARN: attempt $n failed for $f; relaunching and retrying" >&2
    echo "== relaunch (retry) =="
    launch_and_wait
    n=$((n + 1))
  done

  return 1
}

echo "== tests (v1) =="
fail=0
KEEP_GOING="${TERMMESH_E2E_KEEP_GOING:-0}"
positional=()
for arg in "$@"; do
  case "$arg" in
    --keep-going) KEEP_GOING=1 ;;
    *) positional[${#positional[@]}]="$arg" ;;
  esac
done
if [ "${#positional[@]}" -gt 0 ]; then
  test_files=("${positional[@]}")
else
  test_files=(tests/test_*.py)
fi
passed=0
skipped=0
failed_tests=()

for f in "${test_files[@]}"; do
  base=$(basename "$f")
  if [ "$base" = "test_ctrl_interactive.py" ]; then
    echo "SKIP $f"
    skipped=$((skipped + 1))
    continue
  fi

  echo "== launch ($base) =="
  launch_and_wait
  if ! run_test_with_retry "$f"; then
    echo "FAIL $f" >&2
    fail=1
    failed_tests[${#failed_tests[@]}]="$f"
    if [ "$KEEP_GOING" != "1" ]; then
      break
    fi
  else
    passed=$((passed + 1))
  fi
done

echo "== summary =="
echo "passed:  $passed"
echo "failed:  ${#failed_tests[@]}"
echo "skipped: $skipped"
if [ "${#failed_tests[@]}" -gt 0 ]; then
  for t in "${failed_tests[@]}"; do
    echo "  FAIL $t"
  done
fi

echo "== cleanup =="
cleanup

exit "$fail"
