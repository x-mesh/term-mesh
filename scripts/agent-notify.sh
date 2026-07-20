#!/bin/sh
# Raise a term-mesh notification from a CLI agent's hook.
#
# Works the same in a local pane and in one hosted on another machine,
# because it says nothing about where it runs: the notification travels as
# an escape inside the terminal stream the pane already carries. That is the
# same path Claude Code's own notifications take, and the reason this needs
# nothing installed on a relay host beyond the file itself.
#
# OSC 777 rather than OSC 9: only 777 has a title slot, and the title is
# what names the card. A title-less notification falls back to the
# workspace name, which says which window is talking but never which agent.
#
# Usage: wire as the command for an agent's notification-style hook, with
# `--title <name>` naming the agent. Agents disagree on how they hand the
# payload over, so both ways are accepted: a JSON object as the first
# remaining argument, or the same JSON on stdin. Anything else in the
# arguments is taken as the message itself.
#
#   codex   ~/.codex/config.toml   notify = [".../agent-notify.sh",
#                                   "--title", "✳ Codex"]   (JSON in argv;
#                                   Codex has no "Notification" hook event,
#                                   its hook list stops at Stop)
#   claude  ~/.claude/settings.json      "Notification"  (JSON on stdin;
#                                   Claude does this itself when
#                                   agentPushNotifEnabled)
#
# Deliberately POSIX sh with no dependencies beyond printf and, when
# available, python3: a relay host is someone else's machine and may have
# neither jq nor bash.

set -u

TITLE="${TERMMESH_NOTIFY_TITLE:-Agent}"
case "${1:-}" in
    --title) TITLE="${2:-$TITLE}"; shift 2 ;;
esac

MESSAGE=""
PAYLOAD=""

# A leading brace means the agent handed the payload over as an argument
# rather than on stdin, which is how Codex's `notify` calls this. Testing the
# text beats testing the agent: nothing here has to know which one called.
case "${1:-}" in
    \{*) PAYLOAD="$1" ;;
    *)   MESSAGE="$*" ;;
esac

if [ -z "$MESSAGE" ] && [ -z "$PAYLOAD" ] && [ ! -t 0 ]; then
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
for key in ("message", "notification", "body", "text", "reason", "summary",
            "last-assistant-message"):
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
# The title additionally loses `;`, which would shift everything after it
# into the body.
MESSAGE="$(printf '%s' "$MESSAGE" | tr -d '\033\007' | tr '\n' ' ')"
TITLE="$(printf '%s' "$TITLE" | tr -d '\033\007;' | tr '\n' ' ')"

# OSC 777 is what Ghostty parses into a titled desktop notification.
# `/dev/tty` rather than stdout: a hook's stdout is captured by the agent
# and never reaches the terminal. Codex's exec mode detaches this process
# from the terminal entirely - no controlling tty, so `/dev/tty` cannot
# open - while leaving stderr pointed at the pty, so that is the fallback;
# gated on stderr being a terminal so a captured stderr is not fed escapes.
SINK="none"
if printf '\033]777;notify;%s;%s\007' "$TITLE" "$MESSAGE" > /dev/tty 2>/dev/null; then
    SINK="tty"
elif [ -t 2 ]; then
    printf '\033]777;notify;%s;%s\007' "$TITLE" "$MESSAGE" >&2 && SINK="stderr" || true
elif command -v python3 >/dev/null 2>&1; then
    # No terminal at all. Claude Code runs its hooks detached from the
    # terminal, but reads a `terminalSequence` field from a hook's stdout
    # (2.1.141+) and writes the sequence to the terminal on the hook's
    # behalf - the one sanctioned path from a detached hook to the pane.
    printf '\033]777;notify;%s;%s\007' "$TITLE" "$MESSAGE" \
        | python3 -c 'import json, sys; print(json.dumps({"terminalSequence": sys.stdin.read()}))' \
        && SINK="stdout-json"
fi

# Same debug switch as the payload capture above: which sink took the
# escape is the first question when a notification never shows up.
if [ -n "${TERMMESH_NOTIFY_DEBUG:-}" ]; then
    printf 'sink=%s title=%s tty=%s\n' "$SINK" "$TITLE" "$(tty 2>/dev/null || echo none)" \
        >> "${TMPDIR:-/tmp}/term-mesh-agent-notify.log" 2>/dev/null || true
fi

exit 0
