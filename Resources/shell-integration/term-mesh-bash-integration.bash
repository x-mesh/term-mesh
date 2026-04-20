# term-mesh shell integration for bash

_termmesh_send() {
    local payload="$1"
    # All transports suppress responses and errors — these are fire-and-forget
    # telemetry commands (report_pwd, report_git_branch, etc.) where the app
    # response (including "Tab not found") is irrelevant to the shell.
    if command -v ncat >/dev/null 2>&1; then
        printf '%s\n' "$payload" | ncat -U "${TERMMESH_SOCKET_PATH:-$CMUX_SOCKET_PATH}" --send-only 2>/dev/null || true
    elif command -v socat >/dev/null 2>&1; then
        printf '%s\n' "$payload" | socat - "UNIX-CONNECT:${TERMMESH_SOCKET_PATH:-$CMUX_SOCKET_PATH}" >/dev/null 2>&1 || true
    elif command -v nc >/dev/null 2>&1; then
        # Some nc builds don't support unix sockets, but keep as a last-ditch fallback.
        #
        # Important: macOS/BSD nc will often wait for the peer to close the socket
        # after it has finished writing. term-mesh keeps the connection open, so
        # a plain `nc -U` can hang indefinitely and leak background processes.
        #
        # Prefer flags that guarantee we exit after sending, and fall back to a
        # short timeout so we never block sidebar updates.
        if printf '%s\n' "$payload" | nc -N -U "${TERMMESH_SOCKET_PATH:-$CMUX_SOCKET_PATH}" >/dev/null 2>&1; then
            :
        else
            printf '%s\n' "$payload" | nc -w 1 -U "${TERMMESH_SOCKET_PATH:-$CMUX_SOCKET_PATH}" >/dev/null 2>&1 || true
        fi
    fi
}

# Throttle heavy work to avoid prompt latency.
_TERMMESH_PWD_LAST_PWD="${_TERMMESH_PWD_LAST_PWD:-}"
_TERMMESH_GIT_LAST_PWD="${_TERMMESH_GIT_LAST_PWD:-}"
_TERMMESH_GIT_LAST_RUN="${_TERMMESH_GIT_LAST_RUN:-0}"
_TERMMESH_GIT_JOB_PID="${_TERMMESH_GIT_JOB_PID:-}"

_TERMMESH_PORTS_LAST_RUN="${_TERMMESH_PORTS_LAST_RUN:-0}"
_TERMMESH_TTY_NAME="${_TERMMESH_TTY_NAME:-}"
_TERMMESH_TTY_REPORTED="${_TERMMESH_TTY_REPORTED:-0}"

_termmesh_report_tty_once() {
    # Send the TTY name to the app once per session so the batched port scanner
    # knows which TTY belongs to this panel.
    (( _TERMMESH_TTY_REPORTED )) && return 0
    [[ -S "${TERMMESH_SOCKET_PATH:-$CMUX_SOCKET_PATH}" ]] || return 0
    [[ -n "${TERMMESH_TAB_ID:-$CMUX_TAB_ID}" ]] || return 0
    [[ -n "${TERMMESH_PANEL_ID:-$CMUX_PANEL_ID}" ]] || return 0
    [[ -n "$_TERMMESH_TTY_NAME" ]] || return 0
    _TERMMESH_TTY_REPORTED=1
    {
        _termmesh_send "report_tty $_TERMMESH_TTY_NAME --tab=${TERMMESH_TAB_ID:-$CMUX_TAB_ID} --panel=${TERMMESH_PANEL_ID:-$CMUX_PANEL_ID}"
    } >/dev/null 2>&1 &
}

_termmesh_ports_kick() {
    # Lightweight: just tell the app to run a batched scan for this panel.
    # The app coalesces kicks across all panels and runs a single ps+lsof.
    [[ -S "${TERMMESH_SOCKET_PATH:-$CMUX_SOCKET_PATH}" ]] || return 0
    [[ -n "${TERMMESH_TAB_ID:-$CMUX_TAB_ID}" ]] || return 0
    [[ -n "${TERMMESH_PANEL_ID:-$CMUX_PANEL_ID}" ]] || return 0
    _TERMMESH_PORTS_LAST_RUN=$SECONDS
    {
        _termmesh_send "ports_kick --tab=${TERMMESH_TAB_ID:-$CMUX_TAB_ID} --panel=${TERMMESH_PANEL_ID:-$CMUX_PANEL_ID}"
    } >/dev/null 2>&1 &
}

_termmesh_prompt_command() {
    # Pop any leftover kitty keyboard protocol flags. TUI apps (Claude Code CLI,
    # nvim, etc.) push flags via CSI > u on startup and should pop via CSI < u
    # on exit; if they crash or are killed mid-run, the flags stay on the stack
    # and the next Ctrl+C is encoded as \e[99;5u — visible as "9;5u" text when
    # the shell doesn't speak kitty keyboard protocol. No-op when empty.
    printf '\e[<u'

    [[ -S "${TERMMESH_SOCKET_PATH:-$CMUX_SOCKET_PATH}" ]] || return 0
    [[ -n "${TERMMESH_TAB_ID:-$CMUX_TAB_ID}" ]] || return 0
    [[ -n "${TERMMESH_PANEL_ID:-$CMUX_PANEL_ID}" ]] || return 0

    local now=$SECONDS
    local pwd="$PWD"

    # Resolve TTY name once.
    if [[ -z "$_TERMMESH_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ "$t" != "not a tty" ]] && _TERMMESH_TTY_NAME="$t"
    fi

    _termmesh_report_tty_once

    # CWD: keep the app in sync with the actual shell directory.
    if [[ "$pwd" != "$_TERMMESH_PWD_LAST_PWD" ]]; then
        _TERMMESH_PWD_LAST_PWD="$pwd"
        {
            local qpwd="${pwd//\"/\\\"}"
            _termmesh_send "report_pwd \"${qpwd}\" --tab=${TERMMESH_TAB_ID:-$CMUX_TAB_ID} --panel=${TERMMESH_PANEL_ID:-$CMUX_PANEL_ID}"
        } >/dev/null 2>&1 &
    fi

    # Git branch/dirty can change without a directory change (e.g. `git checkout`),
    # so update on every prompt (still async + de-duped by the running-job check).
    # When pwd changes (cd into a different repo), kill the old probe and start fresh
    # so the sidebar picks up the new branch immediately.
    if [[ -n "$_TERMMESH_GIT_JOB_PID" ]] && kill -0 "$_TERMMESH_GIT_JOB_PID" 2>/dev/null; then
        if [[ "$pwd" != "$_TERMMESH_GIT_LAST_PWD" ]]; then
            kill "$_TERMMESH_GIT_JOB_PID" >/dev/null 2>&1 || true
            _TERMMESH_GIT_JOB_PID=""
        fi
    fi

    if [[ -z "$_TERMMESH_GIT_JOB_PID" ]] || ! kill -0 "$_TERMMESH_GIT_JOB_PID" 2>/dev/null; then
        _TERMMESH_GIT_LAST_PWD="$pwd"
        _TERMMESH_GIT_LAST_RUN=$now
        {
            local branch dirty_opt=""
            branch=$(git branch --show-current 2>/dev/null)
            if [[ -n "$branch" ]]; then
                local first
                first=$(git status --porcelain -uno 2>/dev/null | head -1)
                [[ -n "$first" ]] && dirty_opt="--status=dirty"
                _termmesh_send "report_git_branch $branch $dirty_opt --tab=${TERMMESH_TAB_ID:-$CMUX_TAB_ID} --panel=${TERMMESH_PANEL_ID:-$CMUX_PANEL_ID}"
            else
                _termmesh_send "clear_git_branch --tab=${TERMMESH_TAB_ID:-$CMUX_TAB_ID} --panel=${TERMMESH_PANEL_ID:-$CMUX_PANEL_ID}"
            fi
        } >/dev/null 2>&1 &
        _TERMMESH_GIT_JOB_PID=$!
    fi

    # Ports: lightweight kick to the app's batched scanner every ~10s.
    if (( now - _TERMMESH_PORTS_LAST_RUN >= 10 )); then
        _termmesh_ports_kick
    fi
}

_termmesh_install_prompt_command() {
    [[ -n "${_TERMMESH_PROMPT_INSTALLED:-}" ]] && return 0
    _TERMMESH_PROMPT_INSTALLED=1

    local decl
    decl="$(declare -p PROMPT_COMMAND 2>/dev/null || true)"
    if [[ "$decl" == "declare -a"* ]]; then
        local existing=0
        local item
        for item in "${PROMPT_COMMAND[@]}"; do
            [[ "$item" == "_termmesh_prompt_command" ]] && existing=1 && break
        done
        if (( existing == 0 )); then
            PROMPT_COMMAND=("_termmesh_prompt_command" "${PROMPT_COMMAND[@]}")
        fi
    else
        case ";$PROMPT_COMMAND;" in
            *";_termmesh_prompt_command;"*) ;;
            *)
                if [[ -n "$PROMPT_COMMAND" ]]; then
                    PROMPT_COMMAND="_termmesh_prompt_command;$PROMPT_COMMAND"
                else
                    PROMPT_COMMAND="_termmesh_prompt_command"
                fi
                ;;
        esac
    fi
}

# Ensure Resources/bin is at the front of PATH. Shell init (.bashrc/.bash_profile)
# may prepend other dirs that push our wrapper behind the system claude binary.
_termmesh_fix_path() {
    if [[ -n "${GHOSTTY_BIN_DIR:-}" ]]; then
        local bin_dir="${GHOSTTY_BIN_DIR%/MacOS}"
        bin_dir="${bin_dir}/Resources/bin"
        if [[ -d "$bin_dir" ]]; then
            local new_path=":${PATH}:"
            new_path="${new_path//:${bin_dir}:/:}"
            new_path="${new_path#:}"
            new_path="${new_path%:}"
            PATH="${bin_dir}:${new_path}"
        fi
    fi
}
_termmesh_fix_path
unset -f _termmesh_fix_path

_termmesh_install_prompt_command
