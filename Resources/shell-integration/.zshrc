# vim:ft=zsh
#
# ZDOTDIR wrapper: source the user's .zshrc, then load term-mesh integration.
# This runs in the FINAL process after GhosttyKit's exec chain, so functions
# defined here will persist for the entire shell session.

# Source user's .zshrc from $HOME.
builtin typeset _termmesh_file="${HOME}/.zshrc"
[[ ! -r "$_termmesh_file" ]] || builtin source -- "$_termmesh_file"
builtin unset _termmesh_file

# Load Ghostty shell integration if available.
if [[ -o interactive && -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
    builtin typeset _termmesh_ghostty="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
    if [[ -r "$_termmesh_ghostty" ]]; then
        builtin source -- "$_termmesh_ghostty"
    fi
    builtin unset _termmesh_ghostty
fi

# Load term-mesh integration (unless disabled or already loaded).
if [[ -o interactive && "${TERMMESH_SHELL_INTEGRATION:-${CMUX_SHELL_INTEGRATION:-1}}" != "0" && -n "${TERMMESH_SHELL_INTEGRATION_DIR:-${CMUX_SHELL_INTEGRATION_DIR:-}}" ]]; then
    builtin typeset _termmesh_integ="${TERMMESH_SHELL_INTEGRATION_DIR:-$CMUX_SHELL_INTEGRATION_DIR}/term-mesh-zsh-integration.zsh"
    if [[ -r "$_termmesh_integ" ]] && ! builtin whence -w _termmesh_send >/dev/null 2>&1; then
        builtin source -- "$_termmesh_integ"
    fi
    builtin unset _termmesh_integ
fi

# Restore ZDOTDIR so user scripts see the expected value.
builtin unset ZDOTDIR
