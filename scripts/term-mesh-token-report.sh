#!/bin/bash
# term-mesh-token-report.sh — Report terminal output to term-mesh daemon for token counting.
#
# Usage:
#   your-command | term-mesh-token-report.sh [PID]
#
# If PID is not specified, uses $$ (parent shell PID).
# The script passes through stdin to stdout (like tee) while reporting chunks
# to the daemon for token counting.
#
# Example with AI agent:
#   claude --print | term-mesh-token-report.sh
#   # or wrap an existing command:
#   script -q /dev/null your-agent-command | term-mesh-token-report.sh
#
# Integration with shell (add to .zshrc/.bashrc):
#   export TERM_MESH_TOKEN_REPORT=1
#   # Then in your prompt, output is automatically reported

DAEMON_PORT="${TERM_MESH_HTTP_PORT:-9876}"
DAEMON_URL="http://localhost:${DAEMON_PORT}/api/tokens/report"
REPORT_PID="${1:-$$}"
BUFFER=""
BUFFER_SIZE=0
FLUSH_THRESHOLD=512  # Flush every 512 chars

flush_buffer() {
    if [ -n "$BUFFER" ]; then
        # Use curl in background to avoid blocking
        local escaped
        escaped=$(printf '%s' "$BUFFER" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()), end="")')
        curl -s -X POST "$DAEMON_URL" \
            -H 'Content-Type: application/json' \
            -d "{\"pid\": $REPORT_PID, \"text\": $escaped}" \
            > /dev/null 2>&1 &
        BUFFER=""
        BUFFER_SIZE=0
    fi
}

# Pass through stdin to stdout, buffering for token reports
while IFS= read -r line; do
    echo "$line"
    BUFFER="${BUFFER}${line}\n"
    BUFFER_SIZE=$((BUFFER_SIZE + ${#line}))
    if [ $BUFFER_SIZE -ge $FLUSH_THRESHOLD ]; then
        flush_buffer
    fi
done

# Flush remaining
flush_buffer
wait
