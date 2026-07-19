#!/bin/sh
# Raise a term-mesh notification from a CLI agent's hook.
#
# Works the same in a local pane and in one hosted on another machine,
# because it says nothing about where it runs: the notification travels as
# an OSC 9 escape inside the terminal stream the pane already carries. That
# is the same path Claude Code's own notifications take, and the reason this
# needs nothing installed on a relay host beyond the file itself.
#
# Usage: wire as the command for an agent's notification-style hook. The
# hook's JSON payload arrives on stdin; a message may also be passed as
# arguments, which wins when present.
#
#   codex   ~/.codex/hooks.json          "Notification"
#   claude  ~/.claude/settings.json      "Notification"  (Claude does this
#                                         itself when agentPushNotifEnabled)
#
# Deliberately POSIX sh with no dependencies beyond printf and, when
# available, python3: a relay host is someone else's machine and may have
# neither jq nor bash.

set -u

TITLE="${TERMMESH_NOTIFY_TITLE:-Agent}"

# Everything after the options is the message, when given.
MESSAGE="$*"

PAYLOAD=""
if [ -z "$MESSAGE" ] && [ ! -t 0 ]; then
    PAYLOAD="$(cat 2>/dev/null || true)"
fi

# Keep the raw payload when asked. The shape of a hook's JSON is not
# documented anywhere this script can consult, so the first run on a new
# agent is how it gets learned.
if [ -n "${TERMMESH_NOTIFY_DEBUG:-}" ] && [ -n "$PAYLOAD" ]; then
    printf '%s\n' "$PAYLOAD" >> "${TMPDIR:-/tmp}/term-mesh-agent-notify.log" 2>/dev/null || true
fi

if [ -z "$MESSAGE" ] && [ -n "$PAYLOAD" ]; then
    # First field that reads like something a person should see. Tried in
    # order of specificity so a generic "type" never beats a real message.
    MESSAGE="$(
        printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
for key in ("message", "notification", "body", "text", "reason", "summary"):
    value = data.get(key)
    if isinstance(value, str) and value.strip():
        print(value.strip())
        break
' 2>/dev/null || true
    )"
fi

[ -n "$MESSAGE" ] || MESSAGE="is waiting for your input"

# Strip the two bytes that could end the escape early. A notification body
# is attacker-adjacent text - it comes from whatever the agent was doing -
# and letting it close its own sequence would let it write to the terminal.
MESSAGE="$(printf '%s' "$MESSAGE" | tr -d '\033\007' | tr '\n' ' ')"
TITLE="$(printf '%s' "$TITLE" | tr -d '\033\007;' | tr '\n' ' ')"

# OSC 9 with a title, which is what Ghostty parses into a desktop
# notification. `/dev/tty` rather than stdout: a hook's stdout is captured by
# the agent and never reaches the terminal.
printf '\033]9;%s;%s\007' "$TITLE" "$MESSAGE" > /dev/tty 2>/dev/null || true

exit 0
