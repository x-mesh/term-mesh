#!/bin/sh
# Name a pane after the CLI agent running in it.
#
# term-mesh takes a pane's tab and workspace name from the terminal title,
# and Claude Code sets one of its own - which is why a Claude pane reads
# "✳ Claude Code" while a Codex pane reads whatever the shell last left
# there. This closes that gap for the agents that set no title.
#
# Same reasoning as agent-notify.sh, one escape over: the title travels
# in-band as OSC 2, so a pane hosted on another machine is named the same
# way a local one is, with nothing installed on the relay host but this
# file.
#
# Usage: wire as an agent's session-start hook, with the title as its
# arguments. A hook's JSON payload on stdin is read and discarded, which
# keeps the agent from blocking on a pipe nothing drains.
#
#   codex   ~/.codex/hooks.json   SessionStart   .../agent-title.sh "✳ Codex"
#
# POSIX sh, printf only. A relay host may have neither jq nor bash.

set -u

TITLE="$*"
[ -n "$TITLE" ] || TITLE="${TERMMESH_PANE_TITLE:-Agent}"

# Drain stdin so a hook that pipes its payload in never blocks on a reader
# that was not going to look.
if [ ! -t 0 ]; then
    cat > /dev/null 2>&1 || true
fi

# Strip the bytes that could end the escape early, the same way the
# notification body is stripped: a title assembled from anything but a
# literal could otherwise close its own sequence and write to the terminal.
TITLE="$(printf '%s' "$TITLE" | tr -d '\033\007' | tr '\n' ' ')"

# OSC 2 sets the window title, which is the one term-mesh reads. `/dev/tty`
# rather than stdout: a hook's stdout is captured by the agent and never
# reaches the terminal.
printf '\033]2;%s\007' "$TITLE" > /dev/tty 2>/dev/null || true

exit 0
