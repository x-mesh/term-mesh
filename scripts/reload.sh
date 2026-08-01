#!/usr/bin/env bash
set -euo pipefail

APP_NAME="term-mesh DEV"
APP_DISPLAY_NAME="Term-Mesh DEV"
BUNDLE_ID="com.termmesh.app.debug"
BASE_APP_NAME="term-mesh DEV"
DERIVED_DATA=""
NAME_SET=0
BUNDLE_SET=0
DERIVED_SET=0
TAG=""
TERMMESH_DEBUG_LOG=""
ALLOW_ALL=0
USER_ENV=()

usage() {
  cat <<'EOF'
Usage: ./scripts/reload.sh --tag <name> [options]

Options:
  --tag <name>           Required. Short tag for parallel builds (e.g., feature-xyz-lol).
                         Sets app name, bundle id, and derived data path unless overridden.
  --name <app name>      Override app display/bundle name.
  --bundle-id <id>       Override bundle identifier.
  --derived-data <path>  Override derived data path.
  --allow-all            Set TERMMESH_SOCKET_MODE=allowAll (for external socket access).
  --env KEY=VAL          Pass an environment variable to the launched app. Repeatable.
                         Prefixing this script with KEY=VAL does NOT work: the app is
                         started through `open` from a scrubbed subshell, so it inherits
                         only what is handed to it here. Env-gated features (e.g.
                         TERMMESH_COORDINATOR_ENABLED=1) are unreachable without this.
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

daemon_pid_for_socket() {
  local socket_path="$1"
  printf '{"jsonrpc":"2.0","id":1,"method":"daemon.status","params":{}}\n' \
    | nc -U -w 2 "$socket_path" 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys
try: print(json.load(sys.stdin)["result"]["pid"])
except Exception: pass' 2>/dev/null || true
}

stop_daemon_for_socket() {
  local socket_path="$1"
  local pid=""
  local attempt=0
  [[ -S "$socket_path" ]] || return 0

  pid="$(daemon_pid_for_socket "$socket_path")"
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    kill "$pid" 2>/dev/null || true
    for attempt in {1..20}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
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

# Tag builds are ~3.5G of derived data each, so a machine that has run a few
# dozen tagged sessions loses tens of gigabytes to builds nobody will launch
# again. Anything untouched for this many days is reclaimed automatically.
TAG_GC_DAYS="${TERMMESH_RELOAD_TAG_GC_DAYS:-7}"
# Overridable so the sweep can be exercised against a throwaway tree.
TAG_TMP_ROOT="${TERMMESH_RELOAD_TMP_ROOT:-/tmp}"

# A tag directory is Xcode derived data only when it carries a Build/ subtree.
# The same /tmp/term-mesh-* prefix is also used by live infrastructure
# (term-mesh-agent-pipes, term-mesh-worktree-locks, term-mesh-peer-*, relay
# socket dirs), and those must never be swept.
list_stale_tags() {
  local current_slug="$1"
  local path=""
  local tag=""
  local seen=" "

  # NOTE: the trailing slash is load-bearing. /tmp is a symlink to /private/tmp
  # on macOS and find does not follow a symlinked starting point, so scanning
  # bare `/tmp` silently matched nothing and this whole report always read
  # "stale tags: none" while ~100G piled up.
  while IFS= read -r -d '' path; do
    tag="${path##*/term-mesh-}"
    if [[ -z "$tag" || "$tag" == "$current_slug" ]]; then
      continue
    fi
    if [[ ! -d "$path/Build" ]]; then
      continue
    fi
    if [[ "$seen" == *" $tag "* ]]; then
      continue
    fi
    seen="${seen}${tag} "
    printf '%s\n' "$tag"
  done < <(find "${TAG_TMP_ROOT}/" -maxdepth 1 -type d -name 'term-mesh-*' -print0 2>/dev/null)
}

# The launched binary lives inside the tag's own derived data, so any process
# whose command line still mentions that path owns the directory.
tag_is_running() {
  local tag="$1"
  if pgrep -f "${TAG_TMP_ROOT}/term-mesh-${tag}/" >/dev/null 2>&1; then
    return 0
  fi
  # macOS resolves /tmp to /private/tmp in process command lines.
  if pgrep -f "/private/tmp/term-mesh-${tag}/" >/dev/null 2>&1; then
    return 0
  fi
  if pgrep -f "term-mesh DEV ${tag}.app/Contents/MacOS/" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

path_in_use() {
  local target="$1"
  if [[ ! -e "$target" ]]; then
    return 1
  fi
  if ! command -v lsof >/dev/null 2>&1; then
    return 1
  fi
  lsof -- "$target" >/dev/null 2>&1
}

tag_age_days() {
  local path="$1"
  local mtime=""
  mtime="$(stat -f %m "$path" 2>/dev/null || true)"
  if [[ -z "$mtime" ]]; then
    return 1
  fi
  echo $(( ( $(date +%s) - mtime ) / 86400 ))
}

reclaim_stale_tag_builds() {
  local current_slug="$1"
  local tag=""
  local path=""
  local daemon_sock=""
  local age=""
  local reclaimed=0

  if [[ "${TERMMESH_RELOAD_TAG_GC:-1}" != "1" ]]; then
    return 0
  fi

  while IFS= read -r tag; do
    path="${TAG_TMP_ROOT}/term-mesh-${tag}"
    daemon_sock="$HOME/Library/Application Support/term-mesh/term-meshd-dev-${tag}.sock"

    if ! age="$(tag_age_days "$path")"; then
      continue
    fi
    if [[ "$age" -le "$TAG_GC_DAYS" ]]; then
      continue
    fi
    if tag_is_running "$tag"; then
      echo "  kept ${tag} (${age}d) — still running"
      continue
    fi
    if path_in_use "$daemon_sock"; then
      echo "  kept ${tag} (${age}d) — daemon socket in use"
      continue
    fi

    rm -rf "$path" "${TAG_TMP_ROOT}/term-mesh-debug-${tag}.sock"
    rm -f "${TAG_TMP_ROOT}/term-mesh-debug-${tag}.log" "$daemon_sock"
    echo "  reclaimed ${tag} (${age}d)"
    reclaimed=$((reclaimed + 1))
  done < <(list_stale_tags "$current_slug")

  if [[ "$reclaimed" -gt 0 ]]; then
    echo "  ${reclaimed} stale tag build(s) reclaimed"
  fi
}

print_tag_cleanup_reminder() {
  local current_slug="$1"
  local tag=""
  local -a stale_tags=()

  echo
  echo "Tag cleanup status:"
  echo "  current tag: ${current_slug} (keep this running until you verify)"

  reclaim_stale_tag_builds "$current_slug"

  while IFS= read -r tag; do
    stale_tags+=("$tag")
  done < <(list_stale_tags "$current_slug")

  if [[ "${#stale_tags[@]}" -eq 0 ]]; then
    echo "  stale tags: none"
    echo "  stale cleanup: not needed"
  else
    echo "  stale tags (younger than ${TAG_GC_DAYS}d, or still in use):"
    for tag in "${stale_tags[@]}"; do
      echo "    - ${tag}"
    done
    echo "Cleanup stale tags now (they are reclaimed automatically after ${TAG_GC_DAYS}d):"
    for tag in "${stale_tags[@]}"; do
      echo "  pkill -f \"term-mesh DEV ${tag}.app/Contents/MacOS/term-mesh DEV\""
      echo "  rm -rf \"/tmp/term-mesh-${tag}\" \"/tmp/term-mesh-debug-${tag}.sock\""
      echo "  rm -f \"/tmp/term-mesh-debug-${tag}.log\""
      echo "  rm -f \"$HOME/Library/Application Support/term-mesh/term-meshd-dev-${tag}.sock\""
    done
  fi
  echo "After you verify current tag, cleanup command:"
  echo "  pkill -f \"term-mesh DEV ${current_slug}.app/Contents/MacOS/term-mesh DEV\""
  echo "  rm -rf \"/tmp/term-mesh-${current_slug}\" \"/tmp/term-mesh-debug-${current_slug}.sock\""
  echo "  rm -f \"/tmp/term-mesh-debug-${current_slug}.log\""
  echo "  rm -f \"$HOME/Library/Application Support/term-mesh/term-meshd-dev-${current_slug}.sock\""
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
    --env)
      if [[ -z "${2:-}" || "$2" != *=* ]]; then
        echo "error: --env requires KEY=VAL" >&2
        exit 1
      fi
      USER_ENV+=("$2")
      shift 2
      ;;
    --allow-all)
      ALLOW_ALL=1
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

if [[ -z "$TAG" ]]; then
  echo "error: --tag is required (example: ./scripts/reload.sh --tag fix-sidebar-theme)" >&2
  usage
  exit 1
fi

if [[ -n "$TAG" ]]; then
  TAG_ID="$(sanitize_bundle "$TAG")"
  TAG_SLUG="$(sanitize_path "$TAG")"
  if [[ "$NAME_SET" -eq 0 ]]; then
    APP_NAME="term-mesh DEV ${TAG}"
    APP_DISPLAY_NAME="Term-Mesh DEV ${TAG}"
  fi
  if [[ "$BUNDLE_SET" -eq 0 ]]; then
    BUNDLE_ID="com.termmesh.app.debug.${TAG_ID}"
  fi
  if [[ "$DERIVED_SET" -eq 0 ]]; then
    DERIVED_DATA="/tmp/term-mesh-${TAG_SLUG}"
  fi
fi

XCODEBUILD_ARGS=(
  -project GhosttyTabs.xcodeproj
  -scheme term-mesh
  -configuration Debug
  -destination 'platform=macOS'
)
if [[ -n "$DERIVED_DATA" ]]; then
  XCODEBUILD_ARGS+=(-derivedDataPath "$DERIVED_DATA")
fi
if [[ -z "$TAG" ]]; then
  XCODEBUILD_ARGS+=(
    INFOPLIST_KEY_CFBundleName="$APP_DISPLAY_NAME"
    INFOPLIST_KEY_CFBundleDisplayName="$APP_DISPLAY_NAME"
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
  )
fi
XCODEBUILD_ARGS+=(build)

XCODE_LOG="/tmp/term-mesh-xcodebuild-${TAG_SLUG}.log"
xcodebuild "${XCODEBUILD_ARGS[@]}" 2>&1 | tee "$XCODE_LOG" | grep -E '(warning:|error:|fatal:|BUILD FAILED|BUILD SUCCEEDED|\*\* BUILD)' || true
XCODE_EXIT="${PIPESTATUS[0]}"
echo "Full build log: $XCODE_LOG"
if [[ "$XCODE_EXIT" -ne 0 ]]; then
  echo "error: xcodebuild failed with exit code $XCODE_EXIT" >&2
  exit "$XCODE_EXIT"
fi
sleep 0.2

FALLBACK_APP_NAME="$BASE_APP_NAME"
SEARCH_APP_NAME="$APP_NAME"
if [[ -n "$TAG" ]]; then
  SEARCH_APP_NAME="$BASE_APP_NAME"
fi
if [[ -n "$DERIVED_DATA" ]]; then
  APP_PATH="${DERIVED_DATA}/Build/Products/Debug/${SEARCH_APP_NAME}.app"
  if [[ ! -d "${APP_PATH}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_PATH="${DERIVED_DATA}/Build/Products/Debug/${FALLBACK_APP_NAME}.app"
  fi
else
  APP_BINARY="$(
    find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/${SEARCH_APP_NAME}.app/Contents/MacOS/${SEARCH_APP_NAME}" -print0 \
    | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
    | sort -nr \
    | head -n 1 \
    | cut -d' ' -f2-
  )"
  if [[ -n "${APP_BINARY}" ]]; then
    APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
  fi
  if [[ -z "${APP_PATH}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_BINARY="$(
      find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/${FALLBACK_APP_NAME}.app/Contents/MacOS/${FALLBACK_APP_NAME}" -print0 \
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
if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "${APP_NAME}.app not found in DerivedData" >&2
  exit 1
fi

if [[ -n "$TAG" && "$APP_NAME" != "$SEARCH_APP_NAME" ]]; then
  TAG_APP_PATH="$(dirname "$APP_PATH")/${APP_NAME}.app"
  rm -rf "$TAG_APP_PATH"
  cp -R "$APP_PATH" "$TAG_APP_PATH"
  INFO_PLIST="$TAG_APP_PATH/Contents/Info.plist"
  if [[ -f "$INFO_PLIST" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_DISPLAY_NAME" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_DISPLAY_NAME" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_DISPLAY_NAME" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_DISPLAY_NAME" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$INFO_PLIST"
    if [[ -n "${TAG_SLUG:-}" ]]; then
      APP_SUPPORT_DIR="$HOME/Library/Application Support/term-mesh"
      TERMMESH_DAEMON_SOCKET="${APP_SUPPORT_DIR}/term-meshd-dev-${TAG_SLUG}.sock"
      TERMMESH_SOCKET="/tmp/term-mesh-debug-${TAG_SLUG}.sock"
      TERMMESH_DEBUG_LOG="/tmp/term-mesh-debug-${TAG_SLUG}.log"
      echo "$TERMMESH_SOCKET" > /tmp/term-mesh-last-socket-path || true
      echo "$TERMMESH_DEBUG_LOG" > /tmp/term-mesh-last-debug-log-path || true
      /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$INFO_PLIST" 2>/dev/null || true
      /usr/libexec/PlistBuddy -c "Set :LSEnvironment:TERMMESH_DAEMON_UNIX_PATH \"${TERMMESH_DAEMON_SOCKET}\"" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:TERMMESH_DAEMON_UNIX_PATH string \"${TERMMESH_DAEMON_SOCKET}\"" "$INFO_PLIST"
      /usr/libexec/PlistBuddy -c "Set :LSEnvironment:TERMMESH_SOCKET_PATH \"${TERMMESH_SOCKET}\"" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:TERMMESH_SOCKET_PATH string \"${TERMMESH_SOCKET}\"" "$INFO_PLIST"
      /usr/libexec/PlistBuddy -c "Set :LSEnvironment:TERMMESH_DEBUG_LOG \"${TERMMESH_DEBUG_LOG}\"" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:TERMMESH_DEBUG_LOG string \"${TERMMESH_DEBUG_LOG}\"" "$INFO_PLIST"
    fi
  fi
  APP_PATH="$TAG_APP_PATH"
fi

# Ask the old app to terminate cleanly first. Remote agents can make
# applicationShouldTerminate return `.terminateLater` for up to 2.5 seconds,
# so the old fixed 0.3-second delay routinely killed the app before
# applicationWillTerminate could stop its daemon.
/usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
if [[ -z "$TAG" ]]; then
  APP_PROCESS_PATTERN="/${BASE_APP_NAME}.app/Contents/MacOS/${BASE_APP_NAME}"
else
  APP_PROCESS_PATTERN="${APP_NAME}.app/Contents/MacOS/${BASE_APP_NAME}"
fi
if ! wait_for_app_exit "$APP_PROCESS_PATTERN"; then
  # Last resort after the graceful-shutdown budget has elapsed.
  pkill -f "$APP_PROCESS_PATTERN" || true
fi

# Tagged instances have an exact daemon socket, so clean up a pre-owner-watch
# daemon from an older build as well. Do this only after the app has exited;
# unlinking the live control socket first leaves an unreachable daemon behind.
if [[ -n "${TERMMESH_DAEMON_SOCKET:-}" ]]; then
  stop_daemon_for_socket "$TERMMESH_DAEMON_SOCKET"
fi
if [[ -n "${TERMMESH_SOCKET:-}" ]]; then
  rm -f "$TERMMESH_SOCKET"
fi

if [[ -d "$PWD/daemon" && -f "$PWD/daemon/Cargo.toml" ]]; then
  (cd "$PWD/daemon" && cargo build --release 2>/dev/null) || true
fi
BIN_DIR="$APP_PATH/Contents/Resources/bin"
mkdir -p "$BIN_DIR"
for bin in term-meshd term-mesh-run tm-agent term-mesh-peer-relay; do
  src="$PWD/daemon/target/release/$bin"
  if [[ -x "$src" ]]; then
    cp "$src" "$BIN_DIR/$bin"
    chmod +x "$BIN_DIR/$bin"
  fi
done
# Re-sign AFTER copying daemon binaries into Contents/Resources/bin. Doing
# this earlier (right after the Info.plist edits) leaves the resource seal
# pointing at the pre-copy file set; LaunchServices then refuses to launch
# the first time with no surfaced error and the app appears to "not start".
# Surface codesign failures (no silent `2>&1 || true` swallow) so the next
# bin-layout regression is loud.
if [[ -n "$TAG" ]]; then
  /usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$APP_PATH" \
    || echo "warning: codesign re-sign failed; first launch may be rejected" >&2
fi
# Avoid inheriting term-mesh/ghostty environment variables from the terminal that
# runs this script (often inside another term-mesh instance), which can cause
# socket and resource-path conflicts. `open` passes its own environment to a
# freshly-launched app, so scrubbing here keeps the launched app clean.
#
# IMPORTANT: do NOT wrap `open` with `env`/`env -u` to scrub. Invoking `open`
# through `/usr/bin/env` breaks the GUI launch on macOS — `open` returns 0 but
# LaunchServices never actually starts the app (silent "won't start"). Instead
# `unset` the vars inside a subshell and call `open` directly; the scrub still
# applies because the subshell's environment is what the app inherits.
SCRUB_VARS=(
  TERMMESH_SOCKET_PATH
  TERMMESH_TAB_ID
  TERMMESH_PANEL_ID
  TERMMESH_DAEMON_UNIX_PATH
  TERMMESH_TAG
  TERMMESH_DEBUG_LOG
  TERMMESH_BUNDLE_ID
  TERMMESH_SHELL_INTEGRATION
  CMUX_SOCKET_PATH
  CMUX_TAB_ID
  CMUX_PANEL_ID
  CMUXD_UNIX_PATH
  CMUX_TAG
  CMUX_DEBUG_LOG
  CMUX_BUNDLE_ID
  CMUX_SHELL_INTEGRATION
  GHOSTTY_BIN_DIR
  GHOSTTY_RESOURCES_DIR
  GHOSTTY_SHELL_FEATURES
  # Dev shells (including CI/Codex) often force-disable paging by exporting these.
  # Don't leak that into term-mesh, otherwise `git diff` won't page even with PAGER=less.
  GIT_PAGER
  GH_PAGER
  TERMINFO
  XDG_DATA_DIRS
  # A Claude Code pane calling this script carries this marker, and `open`
  # would otherwise hand it down to every pane shell in the launched app.
  # Claude then treats itself as a child session and skips transcript
  # persistence there.
  CLAUDE_CODE_CHILD_SESSION
)

# Launch `open "$APP_PATH"` inside a subshell with the scrub applied and any
# KEY=VAL overrides (passed as args) exported. The subshell isolates the parent
# environment; `open` is invoked directly (never via `env`) so the GUI launch
# succeeds.
open_clean() {
  (
    unset "${SCRUB_VARS[@]}"
    while [[ $# -gt 0 ]]; do
      export "$1"
      shift
    done
    open "$APP_PATH"
  )
}

# Build optional env vars for the open command (KEY=VAL form).
EXTRA_ENV=()
if [[ "$ALLOW_ALL" -eq 1 ]]; then
  EXTRA_ENV+=(TERMMESH_SOCKET_MODE=allowAll)
fi
if [[ ${#USER_ENV[@]} -gt 0 ]]; then
  EXTRA_ENV+=("${USER_ENV[@]}")
fi
if [[ -n "${TAG_SLUG:-}" ]]; then
  # Tagged builds are re-signed every rebuild, so the keychain ACL for the
  # peer-identity item re-prompts each launch — an unanswered prompt
  # deadlocks startup (see PeerIdentity.defaultPeerID). Dev tags use an
  # ephemeral identity instead of the keychain.
  EXTRA_ENV+=(TERMMESH_PEER_IDENTITY_EPHEMERAL=1)
fi

if [[ -n "${TAG_SLUG:-}" && -n "${TERMMESH_SOCKET:-}" ]]; then
  # Ensure tag-specific socket paths win even if the caller has TERMMESH_* overrides.
  open_clean "${EXTRA_ENV[@]}" \
    "TERMMESH_TAG=$TAG_SLUG" \
    "TERMMESH_SOCKET_PATH=$TERMMESH_SOCKET" \
    "TERMMESH_DAEMON_UNIX_PATH=$TERMMESH_DAEMON_SOCKET" \
    "TERMMESH_DEBUG_LOG=$TERMMESH_DEBUG_LOG"
elif [[ -n "${TAG_SLUG:-}" ]]; then
  open_clean "${EXTRA_ENV[@]}" \
    "TERMMESH_TAG=$TAG_SLUG" \
    "TERMMESH_DEBUG_LOG=$TERMMESH_DEBUG_LOG"
else
  echo "/tmp/term-mesh-debug.log" > /tmp/term-mesh-last-debug-log-path || true
  open_clean "${EXTRA_ENV[@]}"
fi
# `open` returns before LaunchServices finishes registering the app's bundle id,
# so an immediate `osascript ... activate` fails with -1728 (errAENoSuchObject).
# Poll up to ~3s until the bundle id is resolvable, then activate.
for _ in {1..15}; do
  osascript -e "tell application id \"${BUNDLE_ID}\" to activate" >/dev/null 2>&1 && break
  sleep 0.2
done

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

if [[ -n "${TAG_SLUG:-}" ]]; then
  print_tag_cleanup_reminder "$TAG_SLUG"
fi
