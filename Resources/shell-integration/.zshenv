# vim:ft=zsh
#
# term-mesh ZDOTDIR bootstrap for zsh.
#
# GhosttyKit already uses a ZDOTDIR injection mechanism for zsh (setting ZDOTDIR
# to Ghostty's integration dir). term-mesh also needs to run its integration, but
# we must restore the user's real ZDOTDIR immediately so that:
# - /etc/zshrc sets HISTFILE relative to the real ZDOTDIR/HOME (shared history)
# - zsh loads the user's real .zprofile/.zshrc normally (no wrapper recursion)
#
# We restore ZDOTDIR from (in priority order):
# - GHOSTTY_ZSH_ZDOTDIR (set by GhosttyKit when it overwrote ZDOTDIR)
# - TERMMESH_ZSH_ZDOTDIR (set by term-mesh when it overwrote a user-provided ZDOTDIR)
# - CMUX_ZSH_ZDOTDIR (legacy fallback)
# - unset (zsh treats unset ZDOTDIR as $HOME)

if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${TERMMESH_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$TERMMESH_ZSH_ZDOTDIR"
    builtin unset TERMMESH_ZSH_ZDOTDIR
elif [[ -n "${CMUX_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$CMUX_ZSH_ZDOTDIR"
    builtin unset CMUX_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

{
    # zsh treats unset ZDOTDIR as if it were HOME. We do the same.
    builtin typeset _termmesh_file="${ZDOTDIR-$HOME}/.zshenv"
    builtin print -- "[tm-zshenv] sourcing user .zshenv: $_termmesh_file interactive=$([[ -o interactive ]] && echo yes || echo no)" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
    [[ ! -r "$_termmesh_file" ]] || builtin source -- "$_termmesh_file"
} always {
    builtin print -- "[tm-zshenv] always block: interactive=$([[ -o interactive ]] && echo yes || echo no) SHELL_INTEGRATION=${TERMMESH_SHELL_INTEGRATION:-unset} INTEGRATION_DIR=${TERMMESH_SHELL_INTEGRATION_DIR:-unset}" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
    if [[ -o interactive ]]; then
        # We overwrote GhosttyKit's injected ZDOTDIR, so manually load Ghostty's
        # zsh integration if available.
        if [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
            builtin typeset _termmesh_ghostty="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
            [[ -r "$_termmesh_ghostty" ]] && builtin source -- "$_termmesh_ghostty"
        fi

        # Load term-mesh integration (unless disabled)
        if [[ "${TERMMESH_SHELL_INTEGRATION:-${CMUX_SHELL_INTEGRATION:-1}}" != "0" && -n "${TERMMESH_SHELL_INTEGRATION_DIR:-${CMUX_SHELL_INTEGRATION_DIR:-}}" ]]; then
            builtin typeset _termmesh_integ="${TERMMESH_SHELL_INTEGRATION_DIR:-$CMUX_SHELL_INTEGRATION_DIR}/term-mesh-zsh-integration.zsh"
            builtin print -- "[tm-zshenv] integ file: $_termmesh_integ readable=$([[ -r "$_termmesh_integ" ]] && echo yes || echo no)" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
            if [[ -r "$_termmesh_integ" ]]; then
                builtin source -- "$_termmesh_integ"
                builtin print -- "[tm-zshenv] source exit=$? _termmesh_send=$(builtin whence -w _termmesh_send 2>&1) precmd_functions=($precmd_functions)" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
            else
                builtin print -- "[tm-zshenv] integ file NOT readable" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
            fi
        else
            builtin print -- "[tm-zshenv] SKIPPED: condition failed SHELL_INTEGRATION=${TERMMESH_SHELL_INTEGRATION:-${CMUX_SHELL_INTEGRATION:-1}} INTEGRATION_DIR=${TERMMESH_SHELL_INTEGRATION_DIR:-${CMUX_SHELL_INTEGRATION_DIR:-empty}}" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
        fi
    else
        builtin print -- "[tm-zshenv] SKIPPED: not interactive" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
    fi

    builtin unset _termmesh_file _termmesh_ghostty _termmesh_integ
}
