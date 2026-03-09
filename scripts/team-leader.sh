#!/bin/bash
# Team Leader Console — interactive REPL for commanding agents
# Launched automatically by TeamOrchestrator in the leader pane.
#
# Numbered shortcuts:
#   1 find the main entry point     — create task + delegate to agent #1
#   2 refactor the login module     — create task + delegate to agent #2
#   * report your status            — broadcast to all
#
# Also supports @name syntax:
#   @explorer find the main entry point
#   @all report your status
#   @status / @inbox / @inbox --all / @destroy / @help

SOCKET="$1"
TEAM="$2"

if [ -z "$SOCKET" ] || [ -z "$TEAM" ]; then
    echo "Usage: team-leader.sh <socket_path> <team_name>"
    exit 1
fi

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

AGENT_NAMES=()

rpc() {
    python3 -c "
import socket, json, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect(sys.argv[2])
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
print(resp.decode().strip() if resp else '{}')
" "$1" "$SOCKET"
}

refresh_agents() {
    AGENT_NAMES=()
    local agents
    agents=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.status\",\"params\":{\"team_name\":\"$TEAM\"}}" | \
    python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    agents = data.get('result', {}).get('agents', [])
    for a in agents:
        print(a['name'])
except:
    pass
" 2>/dev/null)
    if [ -n "$agents" ]; then
        while IFS= read -r name; do
            AGENT_NAMES+=("$name")
        done <<< "$agents"
    fi
}

# Build the shortcut bar: [1:explorer 2:executor *:all]
shortcut_bar() {
    local bar=""
    for i in "${!AGENT_NAMES[@]}"; do
        local n=$((i+1))
        bar+="${GREEN}${n}${NC}:${AGENT_NAMES[$i]}  "
    done
    bar+="${YELLOW}*${NC}:all"
    echo -e "$bar"
}

delegate_to_agent() {
    local agent="$1"
    local msg="$2"
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    local output
    output=$("$script_dir/team.py" delegate "$agent" "$msg" 2>&1)
    local status=$?
    if [ $status -eq 0 ]; then
        task_id=$(printf "%s" "$output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('task', {}).get('id', ''))
except Exception:
    print('')
" 2>/dev/null)
        if [ -n "$task_id" ]; then
            echo -e "${GREEN}-> $agent${NC} ${DIM}(task ${task_id})${NC}"
        else
            echo -e "${GREEN}-> $agent${NC}"
        fi
    else
        echo -e "${RED}Failed ($agent)${NC}"
        echo "$output"
    fi
}

broadcast_to_all() {
    local msg="$1"
    REQ=$(python3 -c "
import json, sys
print(json.dumps({'jsonrpc':'2.0','id':1,'method':'team.broadcast','params':{'team_name':sys.argv[1],'text':sys.argv[2]+'\n'}}))" "$TEAM" "$msg")
    R=$(rpc "$REQ")
    count=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('sent_count',0))" 2>/dev/null)
    echo -e "${GREEN}-> all ($count agent(s))${NC}"
}

show_banner() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  Team Leader Console: ${GREEN}${BOLD}$TEAM${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""
    sleep 2
    refresh_agents
    echo -e " $(shortcut_bar)"
    echo ""
    echo -e " ${DIM}Usage:  <number> <message>   or   * <message>${NC}"
    echo -e " ${DIM}        @name <message>  @status  @inbox  @inbox --all  @destroy  @help${NC}"
    echo ""
}

show_help() {
    refresh_agents
    echo ""
    echo -e "${CYAN}Shortcuts:${NC}"
    for i in "${!AGENT_NAMES[@]}"; do
        local n=$((i+1))
        echo -e "  ${BOLD}$n${NC} <message>  ${DIM}— create task + delegate to ${AGENT_NAMES[$i]}${NC}"
    done
    echo -e "  ${BOLD}*${NC} <message>  ${DIM}— broadcast to all${NC}"
    echo ""
    echo -e "${CYAN}Commands:${NC}"
    for name in "${AGENT_NAMES[@]}"; do
        echo -e "  ${GREEN}@$name${NC} <message>  ${DIM}— create task + delegate${NC}"
    done
    echo -e "  ${YELLOW}@all${NC} <message>      ${DIM}— broadcast to all${NC}"
    echo -e "  ${YELLOW}@status${NC}              ${DIM}— show team status${NC}"
    echo -e "  ${YELLOW}@inbox${NC}               ${DIM}— show active attention items${NC}"
    echo -e "  ${YELLOW}@inbox --all${NC}         ${DIM}— include recent completions${NC}"
    echo -e "  ${YELLOW}@destroy${NC}             ${DIM}— destroy team and exit${NC}"
    echo -e "  ${YELLOW}@help${NC}                ${DIM}— show this help${NC}"
    echo ""
}

show_status() {
    refresh_agents
    R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.status\",\"params\":{\"team_name\":\"$TEAM\"}}")
    echo "$R" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data.get('ok'):
        r = data['result']
        print(f\"Team: {r['team_name']} ({r['agent_count']} agents)\")
        for i, a in enumerate(r['agents'], 1):
            print(f\"  {i}) {a['name']} ({a.get('agent_type','?')}) panel={a['panel_id'][:8]}...\")
    else:
        print(f\"Error: {data.get('error',{}).get('message','unknown')}\")
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null
    echo ""
    echo -e " $(shortcut_bar)"
}

show_inbox() {
    local include_completed="${1:-0}"
    R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.inbox\",\"params\":{\"team_name\":\"$TEAM\"}}")
    echo "$R" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if not data.get('ok'):
        print(f\"Error: {data.get('error',{}).get('message','unknown')}\")
        sys.exit(0)
    items = data.get('result', {}).get('items', [])
    if not items:
        print('No attention items.')
        sys.exit(0)
    def priority(item):
        status = item.get('status', '')
        if status == 'blocked': return 0
        if status == 'review_ready': return 1
        if status == 'stale': return 2
        if status == 'failed': return 3
        if status == 'completed': return 4
        return 5
    items = sorted(
        items,
        key=lambda item: (priority(item), -(item.get('age_seconds') or -1))
    )
    include_completed = sys.argv[1] == '1'
    visible_items = items if include_completed else [item for item in items if item.get('status') != 'completed']
    if not visible_items:
        print('No attention items.' if include_completed else 'No active attention items.')
        sys.exit(0)
    heading = 'Attention items'
    if include_completed:
        heading = 'Attention items + recent completions'
    print(f'{heading}: {len(visible_items)}')
    for item in visible_items[:12]:
        reason = item.get('reason', item.get('status', '?'))
        status = item.get('status', '')
        if status == 'completed':
            summary = item.get('result') or item.get('review_summary') or item.get('task_title') or item.get('summary') or ''
        else:
            summary = item.get('summary') or item.get('task_title') or ''
        agent = item.get('agent_name') or '-'
        age = item.get('age_seconds')
        if age is not None:
            if age < 60:
                age_str = f'{age}s'
            elif age < 3600:
                age_str = f'{age // 60}m'
            else:
                age_str = f'{age // 3600}h'
        else:
            age_str = '-'
        print(f\"  - {reason:<14} {agent:<12} {age_str:>4}  {summary}\")
except Exception as e:
    print(f'Error: {e}')
" "$include_completed" 2>/dev/null
    echo ""
    echo -e " $(shortcut_bar)"
}

show_banner

while true; do
    echo -ne "${CYAN}[$TEAM]${NC} > "
    if ! read -r line; then
        break
    fi

    [ -z "$line" ] && continue

    # --- Numbered shortcuts: "1 message", "2 message", "* message" ---
    if [[ "$line" =~ ^([0-9]+)[[:space:]]+(.+)$ ]]; then
        num="${BASH_REMATCH[1]}"
        msg="${BASH_REMATCH[2]}"
        idx=$((num - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#AGENT_NAMES[@]} ]; then
            delegate_to_agent "${AGENT_NAMES[$idx]}" "$msg"
        else
            echo -e "${RED}No agent #$num. Use 1-${#AGENT_NAMES[@]}${NC}"
        fi
        continue
    fi

    if [[ "$line" =~ ^\*[[:space:]]+(.+)$ ]]; then
        broadcast_to_all "${BASH_REMATCH[1]}"
        continue
    fi

    # --- @ syntax ---
    if [[ "$line" != @* ]]; then
        # Bare number without message
        if [[ "$line" =~ ^[0-9]+$ ]]; then
            echo -e "${DIM}Add a message: $line <your message>${NC}"
        else
            echo -e "${DIM}Use: <number> <message>, * <message>, or @name <message>${NC}"
        fi
        continue
    fi

    target="${line%% *}"
    target="${target#@}"
    message="${line#@$target }"
    [ "$message" = "@$target" ] && message=""

    case "$target" in
        help)
            show_help
            ;;
        status)
            show_status
            ;;
        inbox)
            if [ "$message" = "--all" ]; then
                show_inbox 1
            elif [ -n "$message" ]; then
                echo -e "${RED}Usage: @inbox  or  @inbox --all${NC}"
            else
                show_inbox
            fi
            ;;
        destroy)
            echo -e "${YELLOW}Destroying team '$TEAM'...${NC}"
            rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.destroy\",\"params\":{\"team_name\":\"$TEAM\"}}" > /dev/null 2>&1
            echo -e "${GREEN}Team destroyed.${NC}"
            exit 0
            ;;
        all)
            if [ -z "$message" ]; then
                echo -e "${RED}Usage: @all <message>  or  * <message>${NC}"
                continue
            fi
            broadcast_to_all "$message"
            ;;
        *)
            if [ -z "$message" ]; then
                echo -e "${RED}Usage: @$target <message>${NC}"
                continue
            fi
            delegate_to_agent "$target" "$message"
            ;;
    esac
done
