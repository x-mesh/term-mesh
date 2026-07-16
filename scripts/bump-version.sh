#!/usr/bin/env bash
set -euo pipefail

# Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in the Xcode project,
# and keep the daemon's Cargo package versions (term-meshd, term-mesh-cli,
# and their Cargo.lock entries) in sync with it.
#
# Usage:
#   ./scripts/bump-version.sh           # Auto-bump minor (0.15.0 -> 0.16.0)
#   ./scripts/bump-version.sh 0.16.0    # Set specific version
#   ./scripts/bump-version.sh patch     # Bump patch (0.15.0 -> 0.15.1)
#   ./scripts/bump-version.sh major     # Bump major (0.15.0 -> 1.0.0)
#
# All-or-nothing: every update is written to a temp file and validated
# first. The real files are only touched once every target has staged
# cleanly, so a rejected version string or an unexpected file layout never
# leaves a partial version bump behind.

PROJECT_FILE="GhosttyTabs.xcodeproj/project.pbxproj"
DAEMON_TOML="daemon/term-meshd/Cargo.toml"
CLI_TOML="daemon/term-mesh-cli/Cargo.toml"
DAEMON_LOCK="daemon/Cargo.lock"

PBX_TMP=""
DAEMON_TOML_TMP=""
CLI_TOML_TMP=""
DAEMON_LOCK_TMP=""

cleanup_tmp() {
  # Preserve the script's real exit status: without this, the last
  # command run inside the trap (e.g. a no-op `[[ ]]` test) would
  # silently become the script's reported exit code.
  local rc=$?
  local f
  for f in "$PBX_TMP" "$DAEMON_TOML_TMP" "$CLI_TOML_TMP" "$DAEMON_LOCK_TMP"; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f"
  done
  exit "$rc"
}
trap cleanup_tmp EXIT

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Error: $PROJECT_FILE not found. Run from repo root." >&2
  exit 1
fi
for f in "$DAEMON_TOML" "$CLI_TOML" "$DAEMON_LOCK"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: $f not found. Run from repo root." >&2
    exit 1
  fi
done

# Get current versions
CURRENT_MARKETING=$(grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
MIN_BUILD="$CURRENT_BUILD"

echo "Current: MARKETING_VERSION=$CURRENT_MARKETING, CURRENT_PROJECT_VERSION=$CURRENT_BUILD"

# Keep Sparkle build numbers monotonic with the latest published stable appcast.
# If local build numbers have fallen behind due merges/rebases, auto-correct upward.
LATEST_RELEASE_BUILD="$(
  curl -fsSL --max-time 8 https://github.com/manaflow-ai/term-mesh/releases/latest/download/appcast.xml 2>/dev/null \
    | sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' \
    | head -n1 \
  || true
)"
if [[ "$LATEST_RELEASE_BUILD" =~ ^[0-9]+$ ]]; then
  if (( LATEST_RELEASE_BUILD > MIN_BUILD )); then
    MIN_BUILD="$LATEST_RELEASE_BUILD"
  fi
  echo "Latest release appcast build: $LATEST_RELEASE_BUILD"
else
  echo "Latest release appcast build: unavailable (continuing with local build baseline)"
fi

# Parse current marketing version
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_MARKETING"

# Determine new marketing version
if [[ $# -eq 0 ]] || [[ "$1" == "minor" ]]; then
  NEW_MARKETING="$MAJOR.$((MINOR + 1)).0"
elif [[ "$1" == "patch" ]]; then
  NEW_MARKETING="$MAJOR.$MINOR.$((PATCH + 1))"
elif [[ "$1" == "major" ]]; then
  NEW_MARKETING="$((MAJOR + 1)).0.0"
elif [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  NEW_MARKETING="$1"
else
  echo "Usage: $0 [version|minor|patch|major]" >&2
  echo "  version: specific version like 0.16.0" >&2
  echo "  minor: bump minor version (default)" >&2
  echo "  patch: bump patch version" >&2
  echo "  major: bump major version" >&2
  exit 1
fi

# Always increment build number, and never go backwards relative to published releases.
NEW_BUILD=$((MIN_BUILD + 1))

echo "New:     MARKETING_VERSION=$NEW_MARKETING, CURRENT_PROJECT_VERSION=$NEW_BUILD"

# --- Stage every file update in temp copies first (all-or-nothing) ---

# 1. Xcode project file
PBX_TMP="$(mktemp)"
sed "s/MARKETING_VERSION = $CURRENT_MARKETING;/MARKETING_VERSION = $NEW_MARKETING;/g; \
     s/CURRENT_PROJECT_VERSION = $CURRENT_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" \
  "$PROJECT_FILE" > "$PBX_TMP"
if ! grep -q "MARKETING_VERSION = $NEW_MARKETING;" "$PBX_TMP" \
    || ! grep -q "CURRENT_PROJECT_VERSION = $NEW_BUILD;" "$PBX_TMP"; then
  echo "Error: failed to stage $PROJECT_FILE update (pattern not found). No files changed." >&2
  exit 1
fi

# 2. daemon/term-meshd/Cargo.toml
if ! grep -Eq '^version = "[0-9]+\.[0-9]+\.[0-9]+"$' "$DAEMON_TOML"; then
  echo "Error: no [package] version line found in $DAEMON_TOML. No files changed." >&2
  exit 1
fi
DAEMON_TOML_TMP="$(mktemp)"
sed -E "s/^version = \"[0-9]+\.[0-9]+\.[0-9]+\"\$/version = \"$NEW_MARKETING\"/" "$DAEMON_TOML" > "$DAEMON_TOML_TMP"
if ! grep -q "^version = \"$NEW_MARKETING\"\$" "$DAEMON_TOML_TMP"; then
  echo "Error: failed to stage $DAEMON_TOML update. No files changed." >&2
  exit 1
fi

# 3. daemon/term-mesh-cli/Cargo.toml
if ! grep -Eq '^version = "[0-9]+\.[0-9]+\.[0-9]+"$' "$CLI_TOML"; then
  echo "Error: no [package] version line found in $CLI_TOML. No files changed." >&2
  exit 1
fi
CLI_TOML_TMP="$(mktemp)"
sed -E "s/^version = \"[0-9]+\.[0-9]+\.[0-9]+\"\$/version = \"$NEW_MARKETING\"/" "$CLI_TOML" > "$CLI_TOML_TMP"
if ! grep -q "^version = \"$NEW_MARKETING\"\$" "$CLI_TOML_TMP"; then
  echo "Error: failed to stage $CLI_TOML update. No files changed." >&2
  exit 1
fi

# 4. daemon/Cargo.lock — only the version line directly under the
#    term-meshd / term-mesh-cli [[package]] entries. Third-party crate
#    versions (including any that happen to also read "0.72.0") are
#    left untouched because the rewrite is keyed off the preceding
#    `name = "..."` line, not a blind version-string match.
DAEMON_LOCK_TMP="$(mktemp)"
LOCK_COUNT_FILE="$(mktemp)"
awk -v new_version="$NEW_MARKETING" '
  BEGIN {
    target["term-meshd"] = 1
    target["term-mesh-cli"] = 1
    want_version = 0
    updated = 0
  }
  want_version == 1 && /^version = "[0-9]+\.[0-9]+\.[0-9]+"$/ {
    print "version = \"" new_version "\""
    updated++
    want_version = 0
    next
  }
  {
    want_version = 0
    if ($0 ~ /^name = "/) {
      name = $0
      sub(/^name = "/, "", name)
      sub(/"$/, "", name)
      if (name in target) want_version = 1
    }
    print
  }
  END { print updated > "/dev/stderr" }
' "$DAEMON_LOCK" > "$DAEMON_LOCK_TMP" 2>"$LOCK_COUNT_FILE"
LOCK_UPDATED_COUNT="$(cat "$LOCK_COUNT_FILE")"
rm -f "$LOCK_COUNT_FILE"
if [[ "$LOCK_UPDATED_COUNT" -ne 2 ]]; then
  echo "Error: expected to update 2 package entries in $DAEMON_LOCK, updated $LOCK_UPDATED_COUNT. No files changed." >&2
  exit 1
fi

# --- Every staged file validated above — apply all at once ---
mv "$PBX_TMP" "$PROJECT_FILE"; PBX_TMP=""
mv "$DAEMON_TOML_TMP" "$DAEMON_TOML"; DAEMON_TOML_TMP=""
mv "$CLI_TOML_TMP" "$CLI_TOML"; CLI_TOML_TMP=""
mv "$DAEMON_LOCK_TMP" "$DAEMON_LOCK"; DAEMON_LOCK_TMP=""

# Verify
UPDATED_MARKETING=$(grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
UPDATED_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')

if [[ "$UPDATED_MARKETING" != "$NEW_MARKETING" ]] || [[ "$UPDATED_BUILD" != "$NEW_BUILD" ]]; then
  echo "Error: Version update failed!" >&2
  exit 1
fi

UPDATED_DAEMON_VERSION=$(grep -m1 -E '^version = "' "$DAEMON_TOML" | sed -E 's/^version = "(.*)"$/\1/')
UPDATED_CLI_VERSION=$(grep -m1 -E '^version = "' "$CLI_TOML" | sed -E 's/^version = "(.*)"$/\1/')

if [[ "$UPDATED_DAEMON_VERSION" != "$NEW_MARKETING" ]] || [[ "$UPDATED_CLI_VERSION" != "$NEW_MARKETING" ]]; then
  echo "Error: daemon Cargo.toml version update failed!" >&2
  exit 1
fi

echo "Updated $PROJECT_FILE successfully."
echo "Updated $DAEMON_TOML, $CLI_TOML, and $DAEMON_LOCK to version $NEW_MARKETING."
