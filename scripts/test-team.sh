#!/bin/bash
# term-mesh Multi-Agent Team Test Script
# Usage: ./scripts/test-team.sh [socket_path]
#
# Prerequisites:
#   TERMMESH_SOCKET_MODE=allowAll ./scripts/reload.sh --tag test-team

SOCKET="${1:-/tmp/term-mesh-debug-test-team.sock}"
TEAM="test-team-$$"
WORKDIR="$HOME/work/project/term-mesh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass=0
fail=0

rpc() {
    python3 -c "
import socket, json, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect('$SOCKET')
except Exception as e:
    print(json.dumps({'ok': False, 'error': {'message': str(e)}}))
    sys.exit(0)
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
if resp:
    print(resp.decode().strip())
else:
    print(json.dumps({'ok': False, 'error': {'message': 'No response'}}))
" "$1"
}

is_ok() {
    echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok', False))" 2>/dev/null
}

get_field() {
    echo "$1" | python3 -c "
import sys,json
d = json.load(sys.stdin)
keys = sys.argv[1].split('.')
for k in keys:
    if isinstance(d, dict):
        d = d.get(k, '')
    elif isinstance(d, list):
        d = d[int(k)] if k.isdigit() and int(k) < len(d) else ''
    else:
        d = ''
print(d)
" "$2" 2>/dev/null
}

check() {
    local label="$1" result="$2"
    if [ "$(is_ok "$result")" = "True" ]; then
        echo -e "  ${GREEN}PASS${NC} $label"
        ((pass++))
    else
        local msg
        msg=$(get_field "$result" "error.message")
        echo -e "  ${RED}FAIL${NC} $label: ${msg:-unknown error}"
        ((fail++))
    fi
}

echo -e "${CYAN}=== term-mesh Team Agent Test ===${NC}"
echo "Socket: $SOCKET"
echo "Team:   $TEAM"
echo ""

# --- 1. Socket ---
echo -e "${YELLOW}[1/7] Socket connectivity${NC}"
if [ ! -S "$SOCKET" ]; then
    echo -e "  ${RED}FAIL${NC} Socket not found: $SOCKET"
    echo ""
    echo "  Start the app first:"
    echo -e "  ${CYAN}TERMMESH_SOCKET_MODE=allowAll ./scripts/reload.sh --tag test-team${NC}"
    exit 1
fi
R=$(rpc '{"jsonrpc":"2.0","id":0,"method":"team.list","params":{}}')
check "Socket connected" "$R"

# --- 2. Create team ---
echo -e "${YELLOW}[2/7] team.create (2 agents)${NC}"
CREATE_JSON="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.create\",\"params\":{\"team_name\":\"$TEAM\",\"working_directory\":\"$WORKDIR\",\"leader_session_id\":\"test-leader-$$\",\"agents\":[{\"name\":\"explorer\",\"model\":\"sonnet\",\"agent_type\":\"Explore\",\"color\":\"green\"},{\"name\":\"executor\",\"model\":\"sonnet\",\"agent_type\":\"executor\",\"color\":\"blue\"}]}}"
R=$(rpc "$CREATE_JSON")
check "Team created" "$R"

agent_count=$(get_field "$R" "result.agent_count")
if [ "$agent_count" = "2" ]; then
    echo -e "  ${GREEN}PASS${NC} Agent count = 2"
    ((pass++))
else
    echo -e "  ${RED}FAIL${NC} Expected 2 agents, got $agent_count"
    ((fail++))
fi

# --- 3. Status ---
echo -e "${YELLOW}[3/7] team.status${NC}"
R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"team.status\",\"params\":{\"team_name\":\"$TEAM\"}}")
check "Status retrieved" "$R"

# --- 4. List ---
echo -e "${YELLOW}[4/7] team.list${NC}"
R=$(rpc '{"jsonrpc":"2.0","id":3,"method":"team.list","params":{}}')
check "List retrieved" "$R"

has_team=$(echo "$R" | python3 -c "
import sys, json
data = json.load(sys.stdin)
teams = data.get('result', [])
if isinstance(teams, dict): teams = teams.get('teams', [])
print(any(t.get('team_name') == '$TEAM' for t in teams))
" 2>/dev/null)
if [ "$has_team" = "True" ]; then
    echo -e "  ${GREEN}PASS${NC} Team found in list"
    ((pass++))
else
    echo -e "  ${RED}FAIL${NC} Team not found in list"
    ((fail++))
fi

# --- 5. Send ---
echo -e "${YELLOW}[5/7] team.send${NC}"
sleep 2
R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"team.send\",\"params\":{\"team_name\":\"$TEAM\",\"agent_name\":\"explorer\",\"text\":\"echo TEAM_TEST_OK\\n\"}}")
check "Send to explorer" "$R"

R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"team.send\",\"params\":{\"team_name\":\"$TEAM\",\"agent_name\":\"executor\",\"text\":\"echo TEAM_TEST_OK\\n\"}}")
check "Send to executor" "$R"

# --- 6. Broadcast ---
echo -e "${YELLOW}[6/7] team.broadcast${NC}"
R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"team.broadcast\",\"params\":{\"team_name\":\"$TEAM\",\"text\":\"echo BROADCAST_OK\\n\"}}")
check "Broadcast sent" "$R"

broadcast_count=$(get_field "$R" "result.sent_count")
if [ "$broadcast_count" = "2" ]; then
    echo -e "  ${GREEN}PASS${NC} Broadcast reached 2 agents"
    ((pass++))
else
    echo -e "  ${RED}FAIL${NC} Broadcast reached $broadcast_count agents (expected 2)"
    ((fail++))
fi

# --- 7. Destroy ---
echo -e "${YELLOW}[7/7] team.destroy${NC}"
R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"team.destroy\",\"params\":{\"team_name\":\"$TEAM\"}}")
check "Team destroyed" "$R"

sleep 2
R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"team.status\",\"params\":{\"team_name\":\"$TEAM\"}}")
if [ "$(is_ok "$R")" = "False" ]; then
    echo -e "  ${GREEN}PASS${NC} Team no longer exists"
    ((pass++))
else
    echo -e "  ${RED}FAIL${NC} Team still exists after destroy"
    ((fail++))
fi

# --- Summary ---
echo ""
total=$((pass + fail))
echo -e "${CYAN}=== Results: ${pass}/${total} passed ===${NC}"

if [ "$fail" -gt 0 ]; then
    echo -e "${RED}$fail test(s) failed${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
fi
