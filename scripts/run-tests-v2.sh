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
  echo "Run via: ssh mac-sub 'cd /Users/jinwoo/work/term-mesh && ./scripts/run-tests-v2.sh'" >&2
  echo "Or set TERMMESH_E2E_ALLOWED_HOSTS/USERS explicitly for a dedicated runner." >&2
  exit 2
fi

cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rust/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

preflight_remote_project_fixture() {
  [ "${TERMMESH_E2E_REATTACH_PHASE:-}" = "full" ] || return 0
  [ "${TERMMESH_E2E_REQUIRE_REMOTE_PROJECT:-}" = "1" ] || return 0

  local host="${TERMMESH_E2E_REMOTE_LEADER_HOST:-}"
  local remote_dir="${TERMMESH_E2E_REMOTE_LEADER_DIR:-}"
  local profiles="${TERMMESH_E2E_REMOTE_LEADER_HOST_PROFILE_JSON:-}"
  if [ -z "$host" ] || [ -z "$remote_dir" ] || [ -z "$profiles" ]; then
    echo "ERROR: required remote Project E2E needs host, directory, and seeded host profile JSON." >&2
    return 1
  fi

  local ssh_target
  ssh_target=$(/usr/bin/python3 - "$host" "$profiles" <<'PY'
import json
import sys

host, raw = sys.argv[1:]
try:
    profiles = json.loads(raw)
except (TypeError, ValueError) as exc:
    raise SystemExit(f"invalid remote leader host profile JSON: {exc}")
for profile in profiles:
    target = str(profile.get("sshTarget") or "")
    if target and host == f"ssh:{target}":
        print(target)
        break
else:
    raise SystemExit(f"no seeded profile matches remote host {host!r}")
PY
  ) || return 1

  local remote_dir_q
  printf -v remote_dir_q '%q' "$remote_dir"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$ssh_target" \
    "git -C $remote_dir_q rev-parse --verify HEAD >/dev/null"; then
    echo "ERROR: remote Project source must be a reachable Git checkout with a committed HEAD: $ssh_target:$remote_dir" >&2
    return 1
  fi
  echo "remote Project fixture ready: host=$host source=$remote_dir"
}

verify_runner_checkout() {
  local expected_ghostty actual_ghostty
  expected_ghostty=$(git ls-tree HEAD ghostty | awk '{print $3}')
  actual_ghostty=$(git -C ghostty rev-parse HEAD 2>/dev/null || true)
  if [ -z "$expected_ghostty" ] || [ "$actual_ghostty" != "$expected_ghostty" ]; then
    echo "ERROR: ghostty submodule is not initialized at the commit pinned by this checkout; run ./scripts/setup.sh." >&2
    return 1
  fi
  if [ ! -d GhosttyKit.xcframework ]; then
    echo "ERROR: GhosttyKit.xcframework is missing; run ./scripts/setup.sh before E2E." >&2
    return 1
  fi
}

verify_runner_checkout

DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/term-mesh-tests-v2"
APP="$DERIVED_DATA_PATH/Build/Products/Debug/term-mesh DEV.app"
CLI="$DERIVED_DATA_PATH/Build/Products/Debug/term-mesh"
DAEMON_BIN="$PWD/daemon/target/release/term-meshd"
E2E_RUN_ID="$$"
APP_SOCK_PATH="${TMPDIR:-/tmp}/term-mesh-e2e-app-${E2E_RUN_ID}.sock"
DAEMON_SOCK_PATH="${TMPDIR:-/tmp}/term-meshd-e2e-${E2E_RUN_ID}.sock"
DAEMON_LOG_PATH="/tmp/term-meshd-e2e-${E2E_RUN_ID}.log"
# Mobile remote-control listener (docs/mobile-remote-control.md §9 T7): the
# e2e daemon exposes it on a per-run loopback port in loopback auth mode so
# tests_v2/test_mobile_remote_control.py can drive it without Tailscale.
MOBILE_LISTENER_ADDR="127.0.0.1:$(( 21000 + E2E_RUN_ID % 1000 ))"
E2E_APP_PID=""
E2E_DAEMON_PID=""
E2E_APP_PID_FILE="${TMPDIR:-/tmp}/term-mesh-e2e-app-${E2E_RUN_ID}.pid"
REMOTE_FIXTURE_SSH_TARGET=""
REMOTE_FIXTURE_ROOT=""
# Where the peer's agent CLI symlink pointed before this run, when it resolved.
REMOTE_AGENT_CLI_LINK=""
PYTHON_VENV="$DERIVED_DATA_PATH/python-venv"
PYTHON="$PYTHON_VENV/bin/python3"
SYSTEM_PYTHON="/usr/bin/python3"

stage_remote_relay_fixture() {
  [ "${TERMMESH_E2E_REATTACH_PHASE:-}" = "full" ] || return 0
  [ "${TERMMESH_E2E_REQUIRE_REMOTE_PROJECT:-0}" = "1" ] || return 0
  if [ "${TERMMESH_E2E_STAGE_REMOTE_FIXTURE:-0}" != "1" ]; then
    echo "ERROR: required full relay E2E must set TERMMESH_E2E_STAGE_REMOTE_FIXTURE=1" >&2
    echo "This prevents a stale production daemon from being mistaken for the candidate." >&2
    exit 1
  fi
  REMOTE_FIXTURE_SSH_TARGET="${TERMMESH_E2E_REMOTE_FIXTURE_SSH_TARGET:-}"
  if [ -z "$REMOTE_FIXTURE_SSH_TARGET" ]; then
    echo "ERROR: TERMMESH_E2E_REMOTE_FIXTURE_SSH_TARGET is required" >&2
    exit 1
  fi

  local candidate_sha expected_sha fixture_id remote_version remote_socket remote_dir
  candidate_sha="${TERMMESH_E2E_CANDIDATE_SHA:-}"
  expected_sha="$(git rev-parse HEAD)"
  if [ -z "$candidate_sha" ] || [ "$candidate_sha" != "$expected_sha" ]; then
    echo "ERROR: candidate SHA must equal the exact runner checkout HEAD" >&2
    echo "expected=$expected_sha supplied=${candidate_sha:-<empty>}" >&2
    exit 1
  fi
  if ! git diff --quiet -- daemon Proto || ! git diff --cached --quiet -- daemon Proto; then
    echo "ERROR: daemon/proto must be clean so the remote fixture proves candidate_sha" >&2
    exit 1
  fi

  # The staged daemon runs with XDG_DATA_HOME inside the fixture, so the agent
  # CLI installs a copy of itself there and repoints ~/.local/bin/claude at it.
  # The fixture is deleted on exit, which left that link dangling and the next
  # run could not start a leader at all: "claude is not installed". Remember
  # where it pointed so cleanup can put it back. Only a link that resolves is
  # worth restoring — an already-broken one is not this run's to repair.
  REMOTE_AGENT_CLI_LINK="$(ssh "$REMOTE_FIXTURE_SSH_TARGET" \
    'if [ -e "$HOME/.local/bin/claude" ]; then readlink "$HOME/.local/bin/claude"; fi' \
    2>/dev/null || true)"

  fixture_id="${candidate_sha:0:12}-$E2E_RUN_ID"
  REMOTE_FIXTURE_ROOT="/tmp/term-mesh-release-relay-$fixture_id"
  remote_socket="$REMOTE_FIXTURE_ROOT/peer.sock"
  remote_dir="$REMOTE_FIXTURE_ROOT/src"
  echo "== stage remote candidate fixture ($REMOTE_FIXTURE_SSH_TARGET) =="
  ssh "$REMOTE_FIXTURE_SSH_TARGET" "mkdir -p '$remote_dir'"
  git archive HEAD \
    | ssh "$REMOTE_FIXTURE_SSH_TARGET" \
      "tar -xf - -C '$remote_dir' && cd '$remote_dir' && git init -q && \
       git add -A && git -c user.name=term-mesh-e2e -c user.email=e2e@invalid \
       commit -qm candidate"
  ssh "$REMOTE_FIXTURE_SSH_TARGET" \
    "cd '$REMOTE_FIXTURE_ROOT/src/daemon' && \
     PATH=\"\$HOME/.cargo/bin:\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:\$PATH\" \
     CARGO_TARGET_DIR=/tmp/term-mesh-release-relay-target \
     cargo build --release --locked -p term-meshd -p term-mesh-cli -p tm-agent-bridge"
  remote_version="$(ssh "$REMOTE_FIXTURE_SSH_TARGET" \
    '/tmp/term-mesh-release-relay-target/release/term-meshd --version' | awk '{print $2}')"
  if [ -z "$remote_version" ]; then
    echo "ERROR: staged remote daemon did not report a version" >&2
    exit 1
  fi
  ssh "$REMOTE_FIXTURE_SSH_TARGET" \
    "mkdir -p '$REMOTE_FIXTURE_ROOT/state' '$REMOTE_FIXTURE_ROOT/runtime'; \
     chmod 700 '$REMOTE_FIXTURE_ROOT' '$REMOTE_FIXTURE_ROOT/state' '$REMOTE_FIXTURE_ROOT/runtime'; \
     env XDG_DATA_HOME='$REMOTE_FIXTURE_ROOT/state' XDG_RUNTIME_DIR='$REMOTE_FIXTURE_ROOT/runtime' \
       PATH=/tmp/term-mesh-release-relay-target/release:\$HOME/.cargo/bin:\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:\$PATH \
       TERMMESH_PEER_SOCKET='$remote_socket' \
       TERMMESH_DAEMON_UNIX_PATH='$REMOTE_FIXTURE_ROOT/control.sock' \
       nohup /tmp/term-mesh-release-relay-target/release/term-meshd \
       >'$REMOTE_FIXTURE_ROOT/daemon.log' 2>&1 & echo \$! >'$REMOTE_FIXTURE_ROOT/pid'"
  for _ in {1..120}; do
    if ssh "$REMOTE_FIXTURE_SSH_TARGET" "test -S '$remote_socket'"; then break; fi
    sleep 0.25
  done
  if ! ssh "$REMOTE_FIXTURE_SSH_TARGET" "test -S '$remote_socket'"; then
    echo "ERROR: staged remote peer socket did not become ready" >&2
    ssh "$REMOTE_FIXTURE_SSH_TARGET" "tail -100 '$REMOTE_FIXTURE_ROOT/daemon.log'" >&2 || true
    exit 1
  fi

  export TERMMESH_E2E_REMOTE_LEADER_HOST="ssh:$REMOTE_FIXTURE_SSH_TARGET"
  export TERMMESH_E2E_REMOTE_LEADER_DIR="$remote_dir"
  export TERMMESH_E2E_REMOTE_FIXTURE_CANDIDATE_SHA="$candidate_sha"
  export TERMMESH_E2E_REMOTE_FIXTURE_VERSION="v$remote_version"
  export TERMMESH_E2E_REMOTE_LEADER_HOST_PROFILE_JSON
  TERMMESH_E2E_REMOTE_LEADER_HOST_PROFILE_JSON="[{\"id\":\"11111111-1111-4111-8111-111111111111\",\"displayName\":\"release-candidate-relay\",\"sshTarget\":\"$REMOTE_FIXTURE_SSH_TARGET\",\"remoteSocket\":\"$remote_socket\",\"createdAt\":0}]"
}

cleanup_remote_relay_fixture() {
  [ -n "$REMOTE_FIXTURE_SSH_TARGET" ] || return 0
  [ -n "$REMOTE_FIXTURE_ROOT" ] || return 0
  # Put the agent CLI link back before the directory it points into is removed,
  # and only when this run is what moved it.
  if [ -n "$REMOTE_AGENT_CLI_LINK" ]; then
    ssh "$REMOTE_FIXTURE_SSH_TARGET" \
      "current=\$(readlink \"\$HOME/.local/bin/claude\" 2>/dev/null || true); \
       case \"\$current\" in \
         '$REMOTE_FIXTURE_ROOT'/*) \
           ln -sfn '$REMOTE_AGENT_CLI_LINK' \"\$HOME/.local/bin/claude\";; \
       esac" \
      >/dev/null 2>&1 || true
  fi
  ssh "$REMOTE_FIXTURE_SSH_TARGET" \
    "if test -f '$REMOTE_FIXTURE_ROOT/pid'; then kill \$(cat '$REMOTE_FIXTURE_ROOT/pid') 2>/dev/null || true; fi; rm -rf '$REMOTE_FIXTURE_ROOT'" \
    >/dev/null 2>&1 || true
}

trap 'cleanup_remote_relay_fixture' EXIT
stage_remote_relay_fixture
preflight_remote_project_fixture

echo "== build =="
./scripts/generate-build-info.sh
command -v cargo >/dev/null 2>&1 || { echo "ERROR: cargo not found" >&2; exit 1; }
(cd daemon && cargo build --release)
if [ ! -x "$PYTHON" ] \
  || ! grep -q '^home = /usr/bin$' "$PYTHON_VENV/pyvenv.cfg" 2>/dev/null; then
  rm -rf "$PYTHON_VENV"
  "$SYSTEM_PYTHON" -m venv "$PYTHON_VENV"
fi
"$PYTHON" -m pip install --disable-pip-version-check -q -r tests_v2/requirements.txt
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
# `xcodebuild` copies scripts but not the Rust binaries that an installed app
# exposes under Resources/bin. Tests that found `tm-agent` on the runner PATH
# therefore passed without proving the bundle contract. Materialize the same
# layout as reload/release and re-sign after mutating the app bundle.
APP_BIN_DIR="$APP/Contents/Resources/bin"
mkdir -p "$APP_BIN_DIR"
for bin in term-meshd term-mesh-run tm-agent term-mesh-peer-relay tm-agent-bridge; do
  src="$PWD/daemon/target/release/$bin"
  if [ -x "$src" ]; then
    cp "$src" "$APP_BIN_DIR/$bin"
    chmod +x "$APP_BIN_DIR/$bin"
  fi
done
if [ ! -x "$APP_BIN_DIR/tm-agent" ]; then
  echo "ERROR: bundled tm-agent missing after Cargo build: $APP_BIN_DIR/tm-agent" >&2
  exit 1
fi
/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$APP" >/dev/null
export TERMMESH_CLI="$CLI"
export TERMMESH_CLI_BIN="$CLI"

cleanup() {
  local app_descendants=""
  local relaunched_app_pid=""
  if [ -f "$E2E_APP_PID_FILE" ]; then
    relaunched_app_pid=$(cat "$E2E_APP_PID_FILE" 2>/dev/null || true)
    case "$relaunched_app_pid" in
      ''|*[!0-9]*) ;;
      *) E2E_APP_PID="$relaunched_app_pid" ;;
    esac
  fi
  if [ -n "$E2E_APP_PID" ] && kill -0 "$E2E_APP_PID" 2>/dev/null; then
    local frontier="$E2E_APP_PID" next="" parent child
    while [ -n "$frontier" ]; do
      next=""
      for parent in $frontier; do
        for child in $(ps -axo pid=,ppid= | awk -v p="$parent" '$2 == p { print $1 }'); do
          case " $app_descendants " in *" $child "*) ;; *)
            app_descendants="$app_descendants $child"
            next="$next $child"
          esac
        done
      done
      frontier="$next"
    done
  fi
  if [ -n "$E2E_APP_PID" ]; then kill "$E2E_APP_PID" 2>/dev/null || true; fi
  if [ -n "$E2E_DAEMON_PID" ]; then kill "$E2E_DAEMON_PID" 2>/dev/null || true; fi
  for _ in {1..30}; do
    { [ -z "$E2E_APP_PID" ] || ! kill -0 "$E2E_APP_PID" 2>/dev/null; } \
      && { [ -z "$E2E_DAEMON_PID" ] || ! kill -0 "$E2E_DAEMON_PID" 2>/dev/null; } \
      && break
    sleep 0.1
  done
  if { [ -n "$E2E_APP_PID" ] && kill -0 "$E2E_APP_PID" 2>/dev/null; } \
      || { [ -n "$E2E_DAEMON_PID" ] && kill -0 "$E2E_DAEMON_PID" 2>/dev/null; }; then
    echo "ERROR: E2E app or daemon survived cleanup: app=${E2E_APP_PID:-none} daemon=${E2E_DAEMON_PID:-none}" >&2
    return 1
  fi
  # SSH relay helpers may daemonize/reparent while the app is terminating.
  # Reap only exact descendants captured before SIGTERM; unrelated developer
  # tunnels are never selected by a broad process-name match.
  for child in $app_descendants; do
    kill -0 "$child" 2>/dev/null || continue
    kill "$child" 2>/dev/null || true
  done
  for _ in {1..30}; do
    local survivors=0
    for child in $app_descendants; do
      kill -0 "$child" 2>/dev/null && survivors=$((survivors + 1))
    done
    [ "$survivors" -eq 0 ] && break
    sleep 0.1
  done
  for child in $app_descendants; do
    if kill -0 "$child" 2>/dev/null; then
      echo "ERROR: app descendant survived E2E cleanup: pid=$child" >&2
      return 1
    fi
  done
  E2E_APP_PID=""
  E2E_DAEMON_PID=""
  rm -f "$APP_SOCK_PATH" "$DAEMON_SOCK_PATH" "$E2E_APP_PID_FILE" || true
}

# State a test is allowed to destroy. `SessionRestoreSettings.sessionFilePath` is
# deliberately shared by every build on the machine, so without this a test that
# saved for real would overwrite the developer's own session; the same variable
# moves the project declarations to their own defaults suite.
#
# Reset per test, never between the relaunches inside one — a test that restarts
# the app is asserting on exactly this state surviving.
reset_e2e_state() {
  rm -rf "$E2E_STATE_DIR"
  mkdir -p "$E2E_STATE_DIR"
  defaults delete com.termmesh.e2e >/dev/null 2>&1 || true
  if [ -n "${TERMMESH_E2E_REMOTE_LEADER_HOST_PROFILE_JSON:-}" ]; then
    printf '%s\n' "$TERMMESH_E2E_REMOTE_LEADER_HOST_PROFILE_JSON" \
      > "$E2E_STATE_DIR/peer-host-profiles.json"
  fi
}

E2E_STATE_DIR="${TMPDIR:-/tmp}/termmesh-e2e-state.$$"
export TERMMESH_E2E_STATE_DIR="$E2E_STATE_DIR"
export TERMMESH_E2E_REATTACH_STATE="$E2E_STATE_DIR/remote-project-reattach.json"
export TERMMESH_E2E_MOBILE_ADDR="$MOBILE_LISTENER_ADDR"
# A test that relaunches the app respawns this exact binary with this exact env.
export TERMMESH_APP_BIN="$APP/Contents/MacOS/term-mesh DEV"
export TERMMESH_E2E_APP_PID_FILE="$E2E_APP_PID_FILE"
trap 'cleanup; cleanup_remote_relay_fixture; rm -rf "$E2E_STATE_DIR"; defaults delete com.termmesh.e2e >/dev/null 2>&1 || true' EXIT

launch_and_wait() {
  local preserve_state="${1:-0}"
  cleanup
  if [ "$preserve_state" != "1" ]; then
    reset_e2e_state
  fi
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
  TERM_MESH_MOBILE_ENABLED=1 \
  TERM_MESH_MOBILE_AUTH=loopback \
  TERM_MESH_MOBILE_ADDR="$MOBILE_LISTENER_ADDR" \
  "$DAEMON_BIN" >>"$DAEMON_LOG_PATH" 2>&1 &
  E2E_DAEMON_PID=$!

  # Launch directly with UI test mode enabled so startup follows deterministic test codepaths.
  PROJECT_DIR="$PWD" \
  DAEMON_BINARY_PATH="$PWD/daemon/target/release/term-meshd" \
  TERMMESH_DAEMON_UNIX_PATH="$DAEMON_SOCK_PATH" \
  TERMMESH_SOCKET_PATH="$APP_SOCK_PATH" \
  TERMMESH_ALLOW_SOCKET_OVERRIDE=1 \
  TERMMESH_UI_TEST_MODE=1 \
  "$APP/Contents/MacOS/term-mesh DEV" >/dev/null 2>&1 &
  E2E_APP_PID=$!
  printf '%s\n' "$E2E_APP_PID" > "$E2E_APP_PID_FILE"

  SOCK="$APP_SOCK_PATH"
  for _ in {1..120}; do
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

  DAEMON_SOCK=""
  for _ in {1..80}; do
    for candidate in "$DAEMON_SOCK_PATH" "${TMPDIR:-/tmp}/term-meshd.sock" /tmp/term-meshd.sock; do
      if [ -S "$candidate" ]; then
        DAEMON_SOCK="$candidate"
        break
      fi
    done
    if [ -n "$DAEMON_SOCK" ]; then
      break
    fi
    sleep 0.1
  done
  if [ -n "$DAEMON_SOCK" ]; then
    export TERMMESH_DAEMON_SOCKET="$DAEMON_SOCK"
    export TERMMESH_DAEMON_UNIX_PATH="$DAEMON_SOCK"
  else
    echo "ERROR: daemon socket not ready: $DAEMON_SOCK_PATH" >&2
    exit 1
  fi

  # Ensure LaunchServices has a visible/main window attached for rendering checks.
  open "$APP" >/dev/null 2>&1 || true
  sleep 0.5

  echo "== wait ready =="
  TERMMESH_E2E_PRESERVE_RELAUNCH_STATE="$preserve_state" "$PYTHON" - <<'PY'
import time
import os
import sys

sys.path.insert(0, os.path.join(os.getcwd(), "tests_v2"))
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
preserve_relaunch_state = os.environ.get("TERMMESH_E2E_PRESERVE_RELAUNCH_STATE") == "1"
bootstrap_last = None
for _ in range(0 if preserve_relaunch_state else 3):
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
    if preserve_relaunch_state:
        bootstrap_last = None
    else:
        raise SystemExit(f"ERROR: Failed to bootstrap fresh terminal workspace: {bootstrap_last}")
if bootstrap_last is not None:
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
  local output_file
  output_file=$(mktemp "${TMPDIR:-/tmp}/term-mesh-e2e-output.XXXXXX")

  while [ "$n" -le "$attempts" ]; do
    echo "RUN  $f (attempt $n/$attempts)"
    : > "$output_file"
    set +e
    "$PYTHON" "$f" 2>&1 | tee "$output_file"
    local command_status=${PIPESTATUS[0]}
    set -e
    set +e
    ./scripts/classify-test-result.sh "$command_status" "$output_file"
    local classified=$?
    set -e
    if [ "$classified" -eq 0 ] || [ "$classified" -eq 2 ]; then
      rm -f "$output_file"
      return "$classified"
    fi

    if [ "$n" -ge "$attempts" ]; then
      rm -f "$output_file"
      return 1
    fi

    echo "WARN: attempt $n failed for $f; relaunching and retrying" >&2
    echo "== relaunch (retry) =="
    launch_and_wait
    n=$((n + 1))
  done

  rm -f "$output_file"
  return 1
}

# Stopping at the first failure means a suite with several pre-existing
# failures can only be surveyed by re-running with a growing exclusion list,
# and every re-run repeats the tests that already passed. `--keep-going`
# collects them in one pass instead. The exit status is unchanged: any
# failure still exits non-zero.
KEEP_GOING="${TERMMESH_E2E_KEEP_GOING:-0}"
positional=()
for arg in "$@"; do
  case "$arg" in
    --keep-going)
      KEEP_GOING=1
      ;;
    *)
      # bash 3.2 (the macOS system bash) has no `+=` on empty arrays under
      # `set -u`, so index explicitly.
      positional[${#positional[@]}]="$arg"
      ;;
  esac
done

echo "== tests (v2) =="
fail=0
if [ "${#positional[@]}" -gt 0 ]; then
  test_files=("${positional[@]}")
else
  test_files=(tests_v2/test_*.py)
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
  if [ "$base" = "test_runner_skip_accounting.py" ]; then
    echo "RUN  $f (host-safe; no app launch)"
    if "$PYTHON" "$f"; then
      passed=$((passed + 1))
    else
      fail=1
      failed_tests[${#failed_tests[@]}]="$f"
      [ "$KEEP_GOING" = "1" ] || break
    fi
    continue
  fi
  if [ "$base" = "test_remote_project_restart_reattach.py" ] \
    && [ "${TERMMESH_E2E_REATTACH_PHASE:-}" = "full" ]; then
    phase_result() {
      local output_file="$1"
      shift
      set +e
      "$@" 2>&1 | tee "$output_file"
      local command_status=${PIPESTATUS[0]}
      set -e
      set +e
      ./scripts/classify-test-result.sh "$command_status" "$output_file"
      local classified=$?
      set -e
      return "$classified"
    }
    phase_failed=0
    phase_skipped=0
    phase_output=$(mktemp "${TMPDIR:-/tmp}/term-mesh-phase-output.XXXXXX")
    echo "== launch ($base create) =="
    launch_and_wait
    echo "RUN  $f (phase create)"
    set +e
    phase_result "$phase_output" env TERMMESH_E2E_REATTACH_PHASE=create "$PYTHON" "$f"
    create_result=$?
    set -e
    if [ "$create_result" -eq 2 ]; then
      phase_skipped=1
    elif [ "$create_result" -ne 0 ]; then
      echo "FAIL $f (phase create)" >&2
      phase_failed=1
      failed_tests[${#failed_tests[@]}]="$f:create"
    fi
    if [ "$create_result" -eq 0 ]; then
      echo "== relaunch ($base adopt; fresh viewer installation) =="
      TERMMESH_PEER_IDENTITY_EPHEMERAL=1 launch_and_wait 1
      echo "RUN  $f (phase adopt/reconnect)"
      set +e
      phase_result "$phase_output" env TERMMESH_E2E_REATTACH_PHASE=adopt \
        TERMMESH_E2E_CROSS_INSTALLATION_VIEWER=1 "$PYTHON" "$f"
      adopt_result=$?
      set -e
      if [ "$adopt_result" -eq 2 ]; then
        phase_skipped=1
      elif [ "$adopt_result" -ne 0 ]; then
        echo "FAIL $f (phase adopt/reconnect)" >&2
        phase_failed=1
        failed_tests[${#failed_tests[@]}]="$f:adopt"
      fi

      echo "== relaunch ($base cleanup; original owner identity) =="
      launch_and_wait 1
      echo "RUN  $f (phase owner cleanup)"
      set +e
      phase_result "$phase_output" env TERMMESH_E2E_REATTACH_PHASE=cleanup "$PYTHON" "$f"
      cleanup_result=$?
      set -e
      if [ "$cleanup_result" -eq 2 ]; then
        phase_skipped=1
      elif [ "$cleanup_result" -ne 0 ]; then
        echo "FAIL $f (phase owner cleanup)" >&2
        phase_failed=1
        failed_tests[${#failed_tests[@]}]="$f:cleanup"
      fi
    fi
    rm -f "$phase_output"
    if [ "$phase_failed" -ne 0 ]; then
      fail=1
      [ "$KEEP_GOING" = "1" ] || break
      continue
    fi
    if [ "$phase_skipped" -ne 0 ]; then
      skipped=$((skipped + 1))
    else
      passed=$((passed + 1))
    fi
    continue
  fi

  echo "== launch ($base) =="
  launch_and_wait
  if run_test_with_retry "$f"; then
    test_result=0
  else
    test_result=$?
  fi
  if [ "$test_result" -eq 2 ]; then
    skipped=$((skipped + 1))
  elif [ "$test_result" -ne 0 ]; then
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
if [ "$fail" != "0" ] && [ "$KEEP_GOING" != "1" ]; then
  echo "  (stopped at the first failure; pass --keep-going to survey them all)"
fi

echo "== cleanup =="
cleanup

exit "$fail"
