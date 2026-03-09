#!/bin/bash
# Live team agent demo — creates agents and keeps them running
# Usage: ./scripts/test-team-live.sh [socket_path]
#
# Press Enter to destroy the team when done.

SOCKET="${1:-/tmp/term-mesh-debug-test-team.sock}"
TEAM="live-team"
WORKDIR="$HOME/work/project/term-mesh"

rpc() {
    python3 -c "
import socket, json, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect('$SOCKET')
req = json.loads(sys.argv[1])
sock.sendall((json.dumps(req) + '\n').encode())
resp = b''
sock.settimeout(5)
try:
    while b'\n' not in resp:
        resp += sock.recv(4096)
except socket.timeout:
    pass
sock.close()
print(resp.decode().strip() if resp else '{}')
" "$1"
}

echo "=== Live Team Agent Demo ==="
echo ""

# Clean up any previous live-team
rpc "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"team.destroy\",\"params\":{\"team_name\":\"$TEAM\"}}" > /dev/null 2>&1
sleep 1

# Create team with 2 agents
echo "[1] Creating team '$TEAM' with 2 agents..."
R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.create\",\"params\":{\"team_name\":\"$TEAM\",\"working_directory\":\"$WORKDIR\",\"leader_session_id\":\"live-leader\",\"agents\":[{\"name\":\"explorer\",\"model\":\"sonnet\",\"agent_type\":\"Explore\",\"color\":\"green\"},{\"name\":\"executor\",\"model\":\"sonnet\",\"agent_type\":\"executor\",\"color\":\"blue\"}]}}")
echo "$R" | python3 -m json.tool 2>/dev/null || echo "$R"

echo ""
echo "[2] Team is running! Check the term-mesh app:"
echo "    - Tab: [live-team] explorer  (Claude agent in explore mode)"
echo "    - Tab: [live-team] executor  (Claude agent in executor mode)"
echo ""
echo "    Each tab has the Claude CLI running with team flags."
echo "    The agents should start and show Claude's interface."
echo ""
echo "=== Commands you can try ==="
echo ""
echo "  # Send a task to explorer:"
echo "  ./scripts/test-team-live.sh send explorer 'list all Swift files'"
echo ""
echo "  # Broadcast to all agents:"
echo "  ./scripts/test-team-live.sh broadcast 'report status'"
echo ""

# Interactive mode
if [ "${2:-}" = "send" ]; then
    AGENT="${3:?Usage: $0 send <agent_name> <text>}"
    TEXT="${4:?Usage: $0 send <agent_name> <text>}"
    echo "Sending to $AGENT: $TEXT"
    REQ=$(python3 -c "
import json, sys
print(json.dumps({'jsonrpc':'2.0','id':10,'method':'team.send','params':{'team_name':sys.argv[1],'agent_name':sys.argv[2],'text':sys.argv[3]+'\n'}}))" "$TEAM" "$AGENT" "$TEXT")
    rpc "$REQ"
    exit 0
elif [ "${2:-}" = "broadcast" ]; then
    TEXT="${3:?Usage: $0 broadcast <text>}"
    echo "Broadcasting: $TEXT"
    REQ=$(python3 -c "
import json, sys
print(json.dumps({'jsonrpc':'2.0','id':11,'method':'team.broadcast','params':{'team_name':sys.argv[1],'text':sys.argv[2]+'\n'}}))" "$TEAM" "$TEXT")
    rpc "$REQ"
    exit 0
elif [ "${2:-}" = "destroy" ]; then
    echo "Destroying team..."
    rpc "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"team.destroy\",\"params\":{\"team_name\":\"$TEAM\"}}"
    exit 0
fi

echo "Press Enter to destroy the team, or Ctrl-C to keep it running..."
read -r
echo "Destroying team..."
rpc "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"team.destroy\",\"params\":{\"team_name\":\"$TEAM\"}}"
echo "Done."
