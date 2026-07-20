#!/bin/sh
# Put the agent notification scripts on a relay host.
#
# A pane hosted on another machine raises notifications and names itself
# through escapes in its own terminal stream, so the host needs nothing
# beyond the two scripts themselves - this copies them and, when asked,
# wires Claude Code's hooks to use them. Everything else (parsing,
# attribution, focus-aware suppression) already lives on the viewer side.
#
# Usage:
#   scripts/agent-remote-deploy.sh <ssh-host> [--claude-hooks] \
#       [--bin-dir DIR] [--title NAME]
#
#   <ssh-host>       anything ssh accepts: host, user@host, an ssh config alias
#   --claude-hooks   also wire the remote ~/.claude/settings.json:
#                    Notification + Stop -> agent-notify.sh. Claude runs
#                    hooks with no tty, so the script answers over the
#                    terminalSequence contract (Claude Code 2.1.141+).
#                    Backed up, idempotent, needs python3 on the host.
#   --bin-dir DIR    where the scripts land (default /usr/local/bin;
#                    pick ~/.local/bin for a host without root)
#   --title NAME     the agent name on the notification card
#                    (default "✳ Claude")
#
# The hook wiring loads when the remote agent restarts; the script files
# themselves are read at execution, so re-deploying updated scripts needs
# no restart.

set -u

HOST=""
BIN_DIR="/usr/local/bin"
TITLE="✳ Claude"
WIRE_CLAUDE_HOOKS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --claude-hooks) WIRE_CLAUDE_HOOKS=1; shift ;;
        --bin-dir) BIN_DIR="${2:?--bin-dir needs a path}"; shift 2 ;;
        --title) TITLE="${2:?--title needs a name}"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) HOST="$1"; shift ;;
    esac
done

[ -n "$HOST" ] || { echo "usage: $0 <ssh-host> [--claude-hooks] [--bin-dir DIR] [--title NAME]" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for f in agent-notify.sh agent-title.sh; do
    [ -f "$SCRIPT_DIR/$f" ] || { echo "missing $SCRIPT_DIR/$f - run from a checkout" >&2; exit 1; }
done

echo "==> Copying scripts to $HOST:$BIN_DIR"
scp "$SCRIPT_DIR/agent-notify.sh" "$SCRIPT_DIR/agent-title.sh" "$HOST:$BIN_DIR/" || exit 1
ssh "$HOST" "chmod +x '$BIN_DIR/agent-notify.sh' '$BIN_DIR/agent-title.sh'" || exit 1

# Smoke test the detached path - the one Claude hooks will actually take.
# ssh gives the remote command no tty, so a healthy script must answer
# with the terminalSequence JSON (and prove python3 exists doing so).
echo "==> Smoke test (detached emission)"
OUT="$(printf '{"message":"deploy check"}' | ssh "$HOST" "'$BIN_DIR/agent-notify.sh' --title 'deploy'")"
case "$OUT" in
    *terminalSequence*) echo "    ok: $OUT" ;;
    *) echo "    FAILED - expected terminalSequence JSON, got: ${OUT:-<empty>}" >&2
       echo "    (is python3 installed on the host?)" >&2
       exit 1 ;;
esac

if [ -n "$WIRE_CLAUDE_HOOKS" ]; then
    echo "==> Wiring Claude Code hooks on $HOST"
    ssh "$HOST" "BIN_DIR='$BIN_DIR' NOTIFY_TITLE='$TITLE' python3 -" <<'PYEOF'
import json, os, shutil, sys, time

path = os.path.expanduser("~/.claude/settings.json")
bin_dir = os.environ["BIN_DIR"]
title = os.environ["NOTIFY_TITLE"]
notify = f'{bin_dir}/agent-notify.sh --title "{title}"'

try:
    with open(path) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}

hooks = settings.setdefault("hooks", {})

def wire(event, command):
    entries = hooks.setdefault(event, [])
    for group in entries:
        for hook in group.get("hooks", []):
            if "agent-notify.sh" in hook.get("command", ""):
                hook["command"] = command
                return f"{event}: updated"
    entries.append({"hooks": [{"type": "command", "command": command, "timeout": 5}]})
    return f"{event}: added"

# Notification covers permission requests and the 60s idle prompt; Stop
# covers every turn completion, which is what makes remote notifications
# immediate. Watching-pane suppression happens on the viewer, which is
# the side that actually knows what is focused.
changes = [
    wire("Notification", notify),
    wire("Stop", f"{notify} finished responding"),
]

backup = f"{path}.bak.{time.strftime('%Y%m%d-%H%M%S')}"
if os.path.exists(path):
    shutil.copy2(path, backup)
    print(f"    backup: {backup}")
with open(path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
for change in changes:
    print(f"    {change}")
print("    restart the remote claude to load the hook config")
PYEOF
    [ $? -eq 0 ] || exit 1
fi

echo "==> Done"
