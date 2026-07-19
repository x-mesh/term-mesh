#!/usr/bin/env bash
# Hook: Stop
# On session end: stages all changes, generates a conventional commit message
# via Claude headless mode (claude -p), commits, and logs to CHANGELOG.
# Falls back to a generic WIP message if claude -p fails.

set -euo pipefail

# Skip for team agents — only the leader (or standalone sessions) should auto-commit.
# Agents set TERMMESH_AGENT_NAME; leaders and normal sessions do not.
[[ -n "${TERMMESH_AGENT_NAME:-}" ]] && exit 0

# Resolve the git repo root (worktree-safe)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT="$CLAUDE_PROJECT_DIR"
cd "$REPO_ROOT" || exit 0

# Stage tracked files only (new files require manual git add).
git add -u 2>/dev/null || true
# Alternative: stage all + exclude sensitive patterns
# git add -A 2>/dev/null || true
# git reset HEAD -- '*.env' '*.env.*' '*.pem' '*.key' '*.p12' '*.keystore' \
#   '*.credentials' 'credentials.json' 'secrets.*' \
#   '*.xcarchive' '*.ipa' '*.dmg' 2>/dev/null || true

# Exit if nothing to commit
if git diff-index --quiet HEAD 2>/dev/null; then
  exit 0
fi

# Extract diff for commit message generation (truncated to 2000 lines)
DIFF=$(git diff --cached 2>/dev/null | head -2000)
FILE_COUNT=$(git diff --cached --name-only | wc -l | tr -d ' ')

# Clear term-mesh env vars — claude -p is headless and doesn't need
# shell integration or claude-hook injection. Without this, the term-mesh
# claude wrapper injects Stop hooks that call `term-mesh claude-hook stop`
# which fails with "Tab not found" when the workspace ID is stale.
unset CMUX_SURFACE_ID TERMMESH_TAB_ID CMUX_TAB_ID TERMMESH_PANEL_ID CMUX_PANEL_ID 2>/dev/null || true

# Generate commit message via Claude headless mode
COMMIT_MSG=""
if command -v claude &>/dev/null; then
  COMMIT_MSG=$(echo "$DIFF" | claude -p \
    "You are a commit message generator. Based on the following git diff, write a single commit message.
Rules:
- First line MUST start with 'WIP(scope): short summary' (max 72 chars)
- Always use 'WIP' as the type prefix, never feat/fix/refactor/etc.
- If needed, add a blank line then bullet points for details
- Be concise and specific
- NEVER wrap the message in \`\`\` fenced code-block markers
- Output ONLY the commit message, nothing else" 2>/dev/null) || true
fi

# Strip fenced code-block marker lines (\`\`\` or \`\`\`lang) that the model
# tends to wrap the message in. The .githooks/commit-msg hook does the same,
# but this path commits with hooks enabled only as a backstop — belt and braces.
COMMIT_MSG=$(printf '%s\n' "$COMMIT_MSG" | awk '/^[[:space:]]*```/ { next } { print }')
COMMIT_MSG=$(printf '%s\n' "$COMMIT_MSG" | sed -e '/./,$!d')

# Fallback if claude -p failed or returned empty
if [ -z "$COMMIT_MSG" ]; then
  COMMIT_MSG="wip: update $FILE_COUNT files"
fi

# Commit using -F - to safely handle special characters.
# Hooks stay ENABLED: .githooks/commit-msg is the fence-stripping backstop,
# and --no-verify here is what let ``` markers into history in the first place.
if echo "$COMMIT_MSG" | git commit -F - 2>/dev/null; then
  FIRST_LINE=$(echo "$COMMIT_MSG" | head -1)
  SHORT_SHA=$(git rev-parse --short HEAD 2>/dev/null)
  echo "Auto-committed: ${SHORT_SHA} ${FIRST_LINE} (${FILE_COUNT} files)"
fi

# Update CHANGELOG if it exists
CHANGELOG="$REPO_ROOT/docs/CHANGELOG.md"
if [ -f "$CHANGELOG" ]; then
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
  FIRST_LINE=$(echo "$COMMIT_MSG" | head -1)

  if grep -q '## \[Unreleased\]' "$CHANGELOG"; then
    sed -i '' "/## \[Unreleased\]/a\\
- $TIMESTAMP: $FIRST_LINE" "$CHANGELOG" 2>/dev/null || \
    sed -i "/## \[Unreleased\]/a\\- $TIMESTAMP: $FIRST_LINE" "$CHANGELOG" 2>/dev/null || true
  fi

  git add "$CHANGELOG" 2>/dev/null || true
  if ! git diff-index --quiet HEAD 2>/dev/null; then
    git commit -m "docs: auto-update changelog" --no-verify 2>/dev/null || true
  fi
fi
