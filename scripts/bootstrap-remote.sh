#!/usr/bin/env bash
# bootstrap-remote.sh — set up a term-mesh agent team on a remote Linux host.
#
# Installs Claude Code + tmux on the remote, syncs runbooks, creates an agent
# panel grid, and optionally deploys term-meshd + SSH socket forwarding for
# full tm-agent remote control.
#
# Usage:
#   ./scripts/bootstrap-remote.sh [OPTIONS] <ssh-target>
#
# Examples:
#   # Minimal — 2 agent panes, no term-meshd
#   ./scripts/bootstrap-remote.sh user@dev.example.com
#
#   # Custom session name + 4 agents + socket forwarding
#   ./scripts/bootstrap-remote.sh --session myteam --agents 4 --forward-socket user@dev.example.com
#
#   # Deploy term-meshd binary + socket forwarding
#   ./scripts/bootstrap-remote.sh \
#     --daemon ./daemon/target/x86_64-unknown-linux-musl/release/term-meshd \
#     --forward-socket user@dev.example.com
#
# Options:
#   --session NAME        tmux session name (default: agents)
#   --agents N            number of agent panes, 1-8 (default: 2)
#   --model MODEL         claude model short name (default: claude-sonnet-4-6)
#   --runbooks DIR        local .agent-runbooks dir to sync (default: auto-detect)
#   --key-file FILE       env file with API keys to upload (default: ~/.config/term-mesh/env)
#   --daemon BINARY       term-meshd binary to scp + start on remote (optional)
#   --forward-socket      set up SSH LocalForward so local tm-agent can reach remote daemon
#   --no-claude           skip Node.js / claude installation
#   --no-runbooks         skip runbook rsync
#   --dry-run             print SSH/rsync commands without executing
#   -h, --help            show this message
set -euo pipefail

# ─── defaults ────────────────────────────────────────────────────────────────

SESSION="agents"
AGENT_COUNT=2
MODEL="claude-sonnet-4-6"
RUNBOOKS_DIR=""
KEY_FILE="$HOME/.config/term-mesh/env"
DAEMON_BINARY=""
FORWARD_SOCKET=false
SKIP_CLAUDE=false
SKIP_RUNBOOKS=false
DRY_RUN=false
SSH_TARGET=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

LOCAL_FWD_SOCK="/tmp/term-mesh-remote-$$.sock"

# ─── arg parsing ─────────────────────────────────────────────────────────────

usage() {
    sed -n '3,34p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session)    SESSION="$2";       shift 2 ;;
        --agents)     AGENT_COUNT="$2";   shift 2 ;;
        --model)      MODEL="$2";         shift 2 ;;
        --runbooks)   RUNBOOKS_DIR="$2";  shift 2 ;;
        --key-file)   KEY_FILE="$2";      shift 2 ;;
        --daemon)     DAEMON_BINARY="$2"; shift 2 ;;
        --forward-socket) FORWARD_SOCKET=true; shift ;;
        --no-claude)  SKIP_CLAUDE=true;   shift ;;
        --no-runbooks) SKIP_RUNBOOKS=true; shift ;;
        --dry-run)    DRY_RUN=true;       shift ;;
        -h|--help)    usage 0 ;;
        -*) echo "error: unknown option $1" >&2; usage 1 ;;
        *)
            if [[ -n "$SSH_TARGET" ]]; then
                echo "error: unexpected argument: $1" >&2; usage 1
            fi
            SSH_TARGET="$1"; shift ;;
    esac
done

if [[ -z "$SSH_TARGET" ]]; then
    echo "error: ssh-target required" >&2
    usage 1
fi

if ! [[ "$AGENT_COUNT" =~ ^[1-8]$ ]]; then
    echo "error: --agents must be 1-8" >&2
    exit 1
fi

# ─── auto-detect runbooks dir ────────────────────────────────────────────────

if [[ -z "$RUNBOOKS_DIR" ]]; then
    for candidate in \
        "$REPO_ROOT/.agent-runbooks" \
        "$REPO_ROOT/agent-runbooks" \
        "$(pwd)/.agent-runbooks"
    do
        if [[ -d "$candidate" ]]; then
            RUNBOOKS_DIR="$candidate"
            break
        fi
    done
fi

# ─── helpers ─────────────────────────────────────────────────────────────────

run() {
    if $DRY_RUN; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

ssh_run() {
    run ssh -o LogLevel=QUIET -o StrictHostKeyChecking=accept-new \
        "$SSH_TARGET" "$@"
}

die() { echo "error: $*" >&2; exit 1; }

# ─── cleanup ─────────────────────────────────────────────────────────────────

FWD_PID=""
cleanup() {
    set +e
    if [[ -n "$FWD_PID" ]]; then
        kill "$FWD_PID" 2>/dev/null
        rm -f "$LOCAL_FWD_SOCK"
    fi
}
trap cleanup EXIT

# ─── step 1: verify ssh reachability ─────────────────────────────────────────

echo "==> verifying SSH connection to $SSH_TARGET"
if ! $DRY_RUN; then
    ssh -o LogLevel=QUIET -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 "$SSH_TARGET" true \
        || die "cannot reach $SSH_TARGET — check SSH config"
fi
echo "    OK"

# ─── step 2: install Node.js + claude (unless --no-claude) ───────────────────

if ! $SKIP_CLAUDE; then
    echo "==> checking remote claude installation"
    CLAUDE_INSTALLED=$(ssh_run 'command -v claude >/dev/null 2>&1 && echo yes || echo no' || echo no)
    if [[ "$CLAUDE_INSTALLED" == "yes" ]] && ! $DRY_RUN; then
        REMOTE_VER=$(ssh_run 'claude --version 2>/dev/null | head -1' || echo unknown)
        echo "    already installed: $REMOTE_VER"
    else
        echo "==> installing Node.js 22 LTS + @anthropic-ai/claude-code"
        ssh_run 'bash -s' << 'REMOTE_INSTALL'
set -euo pipefail
if ! command -v node >/dev/null 2>&1 || [[ "$(node --version | cut -d. -f1 | tr -d v)" -lt 22 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
        sudo apt-get install -y nodejs
    elif command -v dnf >/dev/null 2>&1; then
        curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
        sudo dnf install -y nodejs
    else
        echo "error: unsupported package manager — install Node.js 22 manually" >&2
        exit 1
    fi
fi
npm install -g @anthropic-ai/claude-code
REMOTE_INSTALL
        echo "    installed"
    fi

    echo "==> checking remote tmux"
    TMUX_INSTALLED=$(ssh_run 'command -v tmux >/dev/null 2>&1 && echo yes || echo no' || echo no)
    if [[ "$TMUX_INSTALLED" != "yes" ]]; then
        echo "==> installing tmux"
        ssh_run 'bash -s' << 'REMOTE_TMUX'
set -euo pipefail
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y tmux
elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y tmux
else
    echo "error: unsupported package manager — install tmux manually" >&2
    exit 1
fi
REMOTE_TMUX
        echo "    installed"
    else
        echo "    tmux already present"
    fi
fi

# ─── step 3: API key env file ─────────────────────────────────────────────────

echo "==> uploading API key env file"
if [[ ! -f "$KEY_FILE" ]]; then
    echo "    WARNING: $KEY_FILE not found — skipping upload"
    echo "    Create it locally with: mkdir -p $(dirname "$KEY_FILE") && echo 'ANTHROPIC_API_KEY=sk-ant-...' > $KEY_FILE"
else
    run scp -q -o LogLevel=QUIET "$KEY_FILE" "$SSH_TARGET:~/.config/term-mesh/env.tmp"
    ssh_run 'mkdir -p ~/.config/term-mesh && mv ~/.config/term-mesh/env.tmp ~/.config/term-mesh/env && chmod 600 ~/.config/term-mesh/env'
    echo "    uploaded → ~/.config/term-mesh/env (chmod 600)"
fi

# ─── step 4: runbook sync ────────────────────────────────────────────────────

if ! $SKIP_RUNBOOKS; then
    if [[ -n "$RUNBOOKS_DIR" ]]; then
        echo "==> syncing runbooks: $RUNBOOKS_DIR → $SSH_TARGET:~/.agent-runbooks/"
        run rsync -az --delete \
            --exclude='*.secret' \
            --exclude='*.local' \
            -e "ssh -o LogLevel=QUIET -o StrictHostKeyChecking=accept-new" \
            "$RUNBOOKS_DIR/" "$SSH_TARGET:~/.agent-runbooks/"
        echo "    synced"
    else
        echo "    WARNING: no .agent-runbooks dir found — skipping runbook sync"
        echo "    Pass --runbooks <path> or run from the repo root"
    fi
fi

# ─── step 5: deploy term-meshd (optional) ────────────────────────────────────

DAEMON_SOCK=""
if [[ -n "$DAEMON_BINARY" ]]; then
    if ! $DRY_RUN && [[ ! -f "$DAEMON_BINARY" ]]; then
        die "term-meshd binary not found: $DAEMON_BINARY"
    elif $DRY_RUN && [[ ! -f "$DAEMON_BINARY" ]]; then
        echo "    [dry-run] WARNING: $DAEMON_BINARY not found yet (expected cross-compile artifact)"
    fi
    echo "==> deploying term-meshd: $DAEMON_BINARY → $SSH_TARGET:~/bin/term-meshd"
    ssh_run 'mkdir -p ~/bin'
    run scp -q -o LogLevel=QUIET "$DAEMON_BINARY" "$SSH_TARGET:~/bin/term-meshd"
    ssh_run 'chmod +x ~/bin/term-meshd'
    echo "    deployed"

    echo "==> starting term-meshd on remote"
    # Use TERMMESH_DAEMON_UNIX_PATH to put socket in a predictable location
    REMOTE_SOCK="/tmp/term-mesh-daemon-$$.sock"
    ssh_run "bash -c 'TERMMESH_DAEMON_UNIX_PATH=$REMOTE_SOCK nohup ~/bin/term-meshd >~/term-meshd.log 2>&1 </dev/null & echo \$!'" > /tmp/term-meshd-remote-pid-$$ 2>&1
    DAEMON_PID=$(cat /tmp/term-meshd-remote-pid-$$ 2>/dev/null || echo "")
    rm -f /tmp/term-meshd-remote-pid-$$
    echo "    remote pid=$DAEMON_PID, socket=$REMOTE_SOCK"

    # Wait for socket to appear
    if ! $DRY_RUN; then
        echo -n "    waiting for socket"
        for i in $(seq 1 20); do
            if ssh -o LogLevel=QUIET "$SSH_TARGET" "test -S $REMOTE_SOCK" 2>/dev/null; then
                echo " ready"
                DAEMON_SOCK="$REMOTE_SOCK"
                break
            fi
            echo -n "."
            sleep 0.5
        done
        if [[ -z "$DAEMON_SOCK" ]]; then
            echo ""
            echo "    WARNING: daemon socket did not appear — check ~/term-meshd.log on remote"
        fi
    fi
fi

# ─── step 6: create tmux agent panel grid ────────────────────────────────────

echo "==> creating tmux session '$SESSION' with $AGENT_COUNT agent pane(s)"

# Build the remote setup script
AGENT_COUNT_INNER="$AGENT_COUNT"
SESSION_INNER="$SESSION"
MODEL_INNER="$MODEL"

ssh_run 'bash -s' << REMOTE_TMUX_SETUP
set -euo pipefail

SESSION="$SESSION_INNER"
AGENT_COUNT="$AGENT_COUNT_INNER"
MODEL="$MODEL_INNER"
ENV_FILE="\$HOME/.config/term-mesh/env"

# Kill existing session with same name if present
tmux kill-session -t "\$SESSION" 2>/dev/null || true

# Create new detached session
tmux new-session -d -s "\$SESSION" -x 220 -y 50

# Add extra panes (first pane = pane 0 already exists)
for i in \$(seq 1 \$(( AGENT_COUNT - 1 ))); do
    tmux split-window -t "\$SESSION" -v
    tmux select-layout -t "\$SESSION" tiled
done

# Launch claude in each pane
for i in \$(seq 0 \$(( AGENT_COUNT - 1 ))); do
    # Source env file if it exists, then launch claude
    if [[ -f "\$ENV_FILE" ]]; then
        tmux send-keys -t "\$SESSION:0.\$i" "source \$ENV_FILE && claude --model \$MODEL" ""
    else
        tmux send-keys -t "\$SESSION:0.\$i" "claude --model \$MODEL" ""
    fi
    sleep 0.1
    tmux send-keys -t "\$SESSION:0.\$i" "" Enter
    sleep 0.3
done

echo "tmux session '\$SESSION' created with \$AGENT_COUNT pane(s)"
REMOTE_TMUX_SETUP

echo "    done"

# ─── step 7: SSH socket forwarding (optional) ─────────────────────────────────

if $FORWARD_SOCKET && [[ -n "$DAEMON_SOCK" ]]; then
    echo "==> setting up SSH LocalForward: $LOCAL_FWD_SOCK → $SSH_TARGET:$DAEMON_SOCK"
    if ! $DRY_RUN; then
        ssh -f -N -T -q \
            -o LogLevel=QUIET \
            -o ExitOnForwardFailure=yes \
            -o StrictHostKeyChecking=accept-new \
            -L "$LOCAL_FWD_SOCK:$DAEMON_SOCK" \
            "$SSH_TARGET" &
        FWD_PID=$!

        for i in $(seq 1 20); do
            [[ -S "$LOCAL_FWD_SOCK" ]] && break
            sleep 0.2
        done

        if [[ -S "$LOCAL_FWD_SOCK" ]]; then
            echo "    forwarded socket ready: $LOCAL_FWD_SOCK"
            echo ""
            echo "    Use tm-agent with the remote daemon:"
            echo "      TERMMESH_DAEMON_UNIX_PATH=$LOCAL_FWD_SOCK tm-agent team list"
            echo ""
            echo "    Press Ctrl-C to disconnect the tunnel."
            wait "$FWD_PID" 2>/dev/null || true
        else
            echo "    WARNING: forwarded socket did not appear"
        fi
    else
        echo "[dry-run] ssh -f -N -L $LOCAL_FWD_SOCK:$DAEMON_SOCK $SSH_TARGET"
    fi
elif $FORWARD_SOCKET && [[ -z "$DAEMON_SOCK" ]]; then
    echo "    NOTE: --forward-socket requires --daemon; skipping"
fi

# ─── summary ─────────────────────────────────────────────────────────────────

echo ""
echo "==> bootstrap complete"
echo ""
echo "  SSH target : $SSH_TARGET"
echo "  tmux session: $SESSION ($AGENT_COUNT pane(s), model=$MODEL)"
echo ""
echo "  View agents (tmux control mode — iTerm2 / term-mesh):"
echo "    ssh $SSH_TARGET tmux -CC attach -t $SESSION"
echo ""
echo "  View agents (plain terminal):"
echo "    ssh $SSH_TARGET tmux attach -t $SESSION"
echo ""
if [[ -n "$DAEMON_SOCK" ]]; then
    echo "  Remote daemon socket: $SSH_TARGET:$DAEMON_SOCK"
    echo "  Logs: ssh $SSH_TARGET tail -f ~/term-meshd.log"
    echo ""
    echo "  Forward daemon socket for local tm-agent:"
    echo "    ssh -L /tmp/remote.sock:$DAEMON_SOCK $SSH_TARGET -N &"
    echo "    TERMMESH_DAEMON_UNIX_PATH=/tmp/remote.sock tm-agent team list"
    echo ""
fi
EXAMPLE_PANE=$(( AGENT_COUNT > 1 ? 1 : 0 ))
echo "  Send instruction to agent pane $EXAMPLE_PANE:"
echo "    ssh $SSH_TARGET \"tmux send-keys -t $SESSION:0.$EXAMPLE_PANE 'your task here' ''\""
echo "    ssh $SSH_TARGET \"sleep 0.1 && tmux send-keys -t $SESSION:0.$EXAMPLE_PANE '' Enter\""
echo ""
echo "  Collect output from pane $EXAMPLE_PANE:"
echo "    ssh $SSH_TARGET \"tmux capture-pane -t $SESSION:0.$EXAMPLE_PANE -p\""
