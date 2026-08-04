#!/usr/bin/env bash
set -euo pipefail

APP_NAME="term-mesh STAGING"
BUNDLE_ID="com.termmesh.app.staging"
BASE_APP_NAME="term-mesh"
DERIVED_DATA=""
NAME_SET=0
BUNDLE_SET=0
DERIVED_SET=0
TAG=""
CLEANUP_ONLY=0
STAGING_TMP_ROOT="${TERMMESH_RELOAD_TMP_ROOT:-/tmp}"
RELOADS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cargo.sh
. "$RELOADS_SCRIPT_DIR/lib/cargo.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/reloads.sh [options]

Release build with isolated "term-mesh STAGING" identity. Runs side-by-side with
the production term-mesh app.

Options:
  --tag <name>           Short tag for parallel builds (e.g., feature-xyz-lol).
                         Sets app name, bundle id, and derived data path unless overridden.
  --name <app name>      Override app display/bundle name.
  --bundle-id <id>       Override bundle identifier.
  --derived-data <path>  Override derived data path.
  --cleanup              Stop this tagged app and reclaim its managed build artifacts.
                         Requires --tag.
  -h, --help             Show this help.
EOF
}

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\\.+//; s/\\.+$//; s/\\.+/./g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  echo "$cleaned"
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  echo "$cleaned"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      if [[ -z "$TAG" ]]; then
        echo "error: --tag requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --name)
      APP_NAME="${2:-}"
      if [[ -z "$APP_NAME" ]]; then
        echo "error: --name requires a value" >&2
        exit 1
      fi
      NAME_SET=1
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      if [[ -z "$BUNDLE_ID" ]]; then
        echo "error: --bundle-id requires a value" >&2
        exit 1
      fi
      BUNDLE_SET=1
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA="${2:-}"
      if [[ -z "$DERIVED_DATA" ]]; then
        echo "error: --derived-data requires a value" >&2
        exit 1
      fi
      DERIVED_SET=1
      shift 2
      ;;
    --cleanup)
      CLEANUP_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -n "$TAG" ]]; then
  TAG_ID="$(sanitize_bundle "$TAG")"
  TAG_SLUG="$(sanitize_path "$TAG")"
  if [[ "$NAME_SET" -eq 0 ]]; then
    APP_NAME="term-mesh STAGING ${TAG}"
  fi
  if [[ "$BUNDLE_SET" -eq 0 ]]; then
    BUNDLE_ID="com.termmesh.app.staging.${TAG_ID}"
  fi
  if [[ "$DERIVED_SET" -eq 0 ]]; then
    DERIVED_DATA="${STAGING_TMP_ROOT}/term-mesh-staging-${TAG_SLUG}"
  fi
fi

# The app derives its socket path from its bundle id and deliberately ignores
# TERMMESH_SOCKET_PATH for tagged bundles, so that a stale env var cannot
# redirect a tagged build onto the production socket — see
# SocketControlSettings.shouldHonorSocketPathOverride. Follow that convention
# instead of fighting it: computing a different path here means the value
# written to term-mesh-last-socket-path names a file the app never creates, and
# the stale-socket cleanup below scrubs the wrong one, leaving the real socket
# behind on every run.
staging_socket_path() {
  local bid="$1"
  local tag=""
  case "$bid" in
    com.termmesh.app.staging.*)
      # Mirrors SocketControlSettings.sanitizeTag: '.' becomes '-', anything
      # outside [A-Za-z0-9_-] is dropped.
      tag="$(printf '%s' "${bid#com.termmesh.app.staging.}" | sed -E 's/\./-/g; s/[^A-Za-z0-9_-]//g')"
      ;;
  esac
  if [[ -n "$tag" ]]; then
    echo "${STAGING_TMP_ROOT}/term-mesh-staging-${tag}.sock"
  else
    echo "${STAGING_TMP_ROOT}/term-mesh-staging.sock"
  fi
}

STAGING_SLUG="${TAG_SLUG:-staging}"
APP_SUPPORT_DIR="$HOME/Library/Application Support/term-mesh"
TERMMESH_DAEMON_SOCKET="${APP_SUPPORT_DIR}/term-meshd-${STAGING_SLUG}.sock"
TERMMESH_SOCKET="$(staging_socket_path "$BUNDLE_ID")"

# Guards the one rm -rf below: only a path this script chose is reclaimable, and
# only when it is a single component under the staging root and not a symlink.
safe_managed_staging_path() {
  local path="$1"
  case "$path" in
    "${STAGING_TMP_ROOT}"/term-mesh-staging-[a-z0-9]*)
      [[ "${path#"${STAGING_TMP_ROOT}"/term-mesh-staging-}" != */* && ! -L "$path" ]]
      ;;
    *) return 1 ;;
  esac
}

stop_staging_daemon() {
  local socket_path="$1"
  [[ -S "$socket_path" ]] || return 0
  for PID in $(lsof -t "$socket_path" 2>/dev/null); do
    kill "$PID" 2>/dev/null || true
  done
  rm -f "$socket_path"
}

wait_for_app_exit() {
  local pattern="$1"
  local attempt=0
  for attempt in {1..40}; do
    pgrep -f "$pattern" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  return 1
}

if [[ "$CLEANUP_ONLY" -eq 1 ]]; then
  if [[ -z "$TAG" ]]; then
    echo "error: --cleanup requires --tag" >&2
    exit 1
  fi
  APP_PROCESS_PATTERN="${APP_NAME}.app/Contents/MacOS/${BASE_APP_NAME}"
  # A staging app that never finished launching ignores the quit event, so the
  # pkill is the one that actually has to land.
  /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  if ! wait_for_app_exit "$APP_PROCESS_PATTERN"; then
    pkill -f "$APP_PROCESS_PATTERN" || true
  fi
  stop_staging_daemon "$TERMMESH_DAEMON_SOCKET"
  rm -f "$TERMMESH_SOCKET"
  if [[ "$DERIVED_SET" -eq 1 ]]; then
    echo "note: --derived-data is caller-owned; left in place: ${DERIVED_DATA}"
  elif safe_managed_staging_path "$DERIVED_DATA"; then
    rm -rf "$DERIVED_DATA"
  else
    echo "note: not a managed staging path; left in place: ${DERIVED_DATA}" >&2
  fi
  echo "reclaimed staging build ${TAG_SLUG}"
  exit 0
fi

XCODEBUILD_ARGS=(
  -project GhosttyTabs.xcodeproj
  -scheme term-mesh
  -configuration Release
  -destination 'platform=macOS'
)
if [[ -n "$DERIVED_DATA" ]]; then
  XCODEBUILD_ARGS+=(-derivedDataPath "$DERIVED_DATA")
fi
if [[ -z "$TAG" ]]; then
  XCODEBUILD_ARGS+=(
    INFOPLIST_KEY_CFBundleName="$APP_NAME"
    INFOPLIST_KEY_CFBundleDisplayName="$APP_NAME"
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
  )
fi
XCODEBUILD_ARGS+=(build)

xcodebuild "${XCODEBUILD_ARGS[@]}"
sleep 0.2

FALLBACK_APP_NAME="$BASE_APP_NAME"
SEARCH_APP_NAME="$APP_NAME"
if [[ -n "$TAG" ]]; then
  SEARCH_APP_NAME="$BASE_APP_NAME"
fi
if [[ -n "$DERIVED_DATA" ]]; then
  APP_PATH="${DERIVED_DATA}/Build/Products/Release/${SEARCH_APP_NAME}.app"
  if [[ ! -d "${APP_PATH}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_PATH="${DERIVED_DATA}/Build/Products/Release/${FALLBACK_APP_NAME}.app"
  fi
else
  APP_BINARY="$(
    find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/${SEARCH_APP_NAME}.app/Contents/MacOS/${SEARCH_APP_NAME}" -print0 \
    | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
    | sort -nr \
    | head -n 1 \
    | cut -d' ' -f2-
  )"
  if [[ -n "${APP_BINARY}" ]]; then
    APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
  fi
  if [[ -z "${APP_PATH:-}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_BINARY="$(
      find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/${FALLBACK_APP_NAME}.app/Contents/MacOS/${FALLBACK_APP_NAME}" -print0 \
      | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
      | sort -nr \
      | head -n 1 \
      | cut -d' ' -f2-
    )"
    if [[ -n "${APP_BINARY}" ]]; then
      APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
    fi
  fi
fi
if [[ -z "${APP_PATH:-}" || ! -d "${APP_PATH}" ]]; then
  echo "${APP_NAME}.app not found in DerivedData" >&2
  exit 1
fi

# Staging always copies the built app and patches the plist to set an isolated
# socket path, bundle id, and display name. This prevents conflicts with the
# production term-mesh app.
STAGING_APP_PATH="$(dirname "$APP_PATH")/${APP_NAME}.app"
rm -rf "$STAGING_APP_PATH"
cp -R "$APP_PATH" "$STAGING_APP_PATH"
INFO_PLIST="$STAGING_APP_PATH/Contents/Info.plist"
if [[ -f "$INFO_PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$INFO_PLIST"

  # Inject staging socket paths via LSEnvironment so the Release binary
  # (which defaults to /tmp/term-mesh.sock) uses isolated sockets instead.
  # The paths themselves are resolved before the build, so --cleanup can find
  # them without rebuilding.
  echo "$TERMMESH_SOCKET" > "${STAGING_TMP_ROOT}/term-mesh-last-socket-path" || true
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$INFO_PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:TERMMESH_DAEMON_UNIX_PATH \"${TERMMESH_DAEMON_SOCKET}\"" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:TERMMESH_DAEMON_UNIX_PATH string \"${TERMMESH_DAEMON_SOCKET}\"" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:TERMMESH_SOCKET_PATH \"${TERMMESH_SOCKET}\"" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:TERMMESH_SOCKET_PATH string \"${TERMMESH_SOCKET}\"" "$INFO_PLIST"
  if [[ -S "$TERMMESH_DAEMON_SOCKET" ]]; then
    for PID in $(lsof -t "$TERMMESH_DAEMON_SOCKET" 2>/dev/null); do
      kill "$PID" 2>/dev/null || true
    done
    rm -f "$TERMMESH_DAEMON_SOCKET"
  fi
  if [[ -S "$TERMMESH_SOCKET" ]]; then
    rm -f "$TERMMESH_SOCKET"
  fi
  /usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$STAGING_APP_PATH" >/dev/null 2>&1 || true
fi
APP_PATH="$STAGING_APP_PATH"

# Ensure any running instance is fully terminated, regardless of DerivedData path.
/usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
sleep 0.3
# Kill any running staging instance; allow side-by-side with the main and dev apps.
pkill -f "${APP_NAME}.app/Contents/MacOS/${BASE_APP_NAME}" || true
sleep 0.3
# daemon is a cargo project (no build.zig). Build all four binaries with cargo
# and copy from target/release, matching reloadp.sh / reload.sh. The previous
# `zig build` + `zig-out/bin/term-meshd` path silently failed ("no build.zig
# file found"), so term-meshd was never copied and STAGING ran a stale daemon.
# Having no cargo at all is a warning; a daemon build that failed is fatal.
# Falling back to whatever daemon/target/release already holds means launching a
# binary this run did not produce, possibly from another branch — the failure
# then looks like a successful build.
DAEMON_BUILT=0
if [[ -d "$PWD/daemon" && -f "$PWD/daemon/Cargo.toml" ]]; then
  if ! resolve_cargo; then
    echo "warning: cargo not found — no daemon binaries will be copied into the bundle" >&2
  elif ! (cd "$PWD/daemon" && "$CARGO_BIN" build --release); then
    echo "error: daemon build failed — refusing to launch with a daemon this build did not produce" >&2
    exit 1
  else
    DAEMON_BUILT=1
  fi
fi
BIN_DIR="$APP_PATH/Contents/Resources/bin"
mkdir -p "$BIN_DIR"
# Only what this run built. daemon/target/release survives between runs and
# holds whatever was last built there, from whatever branch — on one machine it
# was two days and several branches old, and got shipped into the bundle twice
# because cargo was missing and the failure was only a warning.
for bin in term-meshd term-mesh-run tm-agent term-mesh-peer-relay; do
  [[ "$DAEMON_BUILT" -eq 1 ]] || continue
  src="$PWD/daemon/target/release/$bin"
  if [[ -x "$src" ]]; then
    cp "$src" "$BIN_DIR/$bin"
    chmod +x "$BIN_DIR/$bin"
  fi
done
# Re-seal: the codesign above ran before these binaries were copied, so the
# bundle's _CodeSignature no longer matches Resources/bin. Re-sign the whole
# app so macOS doesn't reject the swapped daemon/CLI on launch.
/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$APP_PATH" >/dev/null 2>&1 || true
# Avoid inheriting term-mesh/ghostty environment variables from the terminal that
# runs this script (often inside another term-mesh instance), which can cause
# socket and resource-path conflicts.
OPEN_CLEAN_ENV=(
  env
  -u TERMMESH_SOCKET_PATH
  -u TERMMESH_TAB_ID
  -u TERMMESH_PANEL_ID
  -u TERMMESH_DAEMON_UNIX_PATH
  -u TERMMESH_TAG
  -u TERMMESH_BUNDLE_ID
  -u TERMMESH_SHELL_INTEGRATION
  -u CMUX_SOCKET_PATH
  -u CMUX_TAB_ID
  -u CMUX_PANEL_ID
  -u CMUXD_UNIX_PATH
  -u CMUX_TAG
  -u CMUX_BUNDLE_ID
  -u CMUX_SHELL_INTEGRATION
  -u GHOSTTY_BIN_DIR
  -u GHOSTTY_RESOURCES_DIR
  -u GHOSTTY_SHELL_FEATURES
  # Dev shells (including CI/Codex) often force-disable paging by exporting these.
  # Don't leak that into term-mesh, otherwise `git diff` won't page even with PAGER=less.
  -u GIT_PAGER
  -u GH_PAGER
  -u TERMINFO
  -u XDG_DATA_DIRS
)

# Always inject staging socket paths via env to ensure they take effect
# (LSEnvironment requires app restart to pick up plist changes).
# STAGING is an isolated verification instance, so allow external tooling
# (e.g. `tm-agent` run from a non-term-mesh shell) to drive it over the socket.
"${OPEN_CLEAN_ENV[@]}" TERMMESH_SOCKET_PATH="$TERMMESH_SOCKET" TERMMESH_DAEMON_UNIX_PATH="$TERMMESH_DAEMON_SOCKET" open "$APP_PATH" --env TERMMESH_SOCKET_MODE=allowAll
osascript -e "tell application id \"${BUNDLE_ID}\" to activate" || true

echo "socket: ${TERMMESH_SOCKET}"
if [[ -n "$TAG" ]]; then
  # Release derived data is several GB per tag and nothing sweeps it, so say how
  # to get it back.
  echo "cleanup: ./scripts/reloads.sh --tag ${TAG} --cleanup"
fi

# Safety: ensure only one instance is running.
sleep 0.2
PIDS=($(pgrep -f "${APP_PATH}/Contents/MacOS/" || true))
if [[ "${#PIDS[@]}" -gt 1 ]]; then
  NEWEST_PID=""
  NEWEST_AGE=999999
  for PID in "${PIDS[@]}"; do
    AGE="$(ps -o etimes= -p "$PID" | tr -d ' ')"
    if [[ -n "$AGE" && "$AGE" -lt "$NEWEST_AGE" ]]; then
      NEWEST_AGE="$AGE"
      NEWEST_PID="$PID"
    fi
  done
  for PID in "${PIDS[@]}"; do
    if [[ "$PID" != "$NEWEST_PID" ]]; then
      kill "$PID" 2>/dev/null || true
    fi
  done
fi
