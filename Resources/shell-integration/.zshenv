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
    [[ ! -r "$_termmesh_file" ]] || builtin source -- "$_termmesh_file"
} always {
    if [[ -o interactive ]]; then
        # We overwrote GhosttyKit's injected ZDOTDIR, so manually load Ghostty's
        # zsh integration if available.
        if [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
            builtin typeset _termmesh_ghostty="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
            [[ -r "$_termmesh_ghostty" ]] && builtin source -- "$_termmesh_ghostty"
        fi

        # NOTE: term-mesh integration is NOT loaded here.  Ghostty's .zshenv
        # always block runs AFTER this file and clears all functions/hooks
        # defined here.  The integration is loaded from the user's .zshrc
        # instead (via the TERMMESH_SHELL_INTEGRATION_DIR env var).
    fi

    builtin unset _termmesh_file _termmesh_ghostty
}
