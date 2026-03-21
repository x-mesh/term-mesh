# vim:ft=zsh
#
# term-mesh ZDOTDIR bootstrap for zsh.
#
# ZDOTDIR is kept pointing at this integration directory throughout the entire
# shell lifecycle so that .zprofile/.zshrc also load from here.  This is
# essential because GhosttyKit's macOS exec chain (login → bash → exec -l zsh)
# replaces the process between .zshenv and .zprofile, destroying any functions
# defined in .zshenv.  By keeping ZDOTDIR here, .zshrc (which runs in the
# final process) can load term-mesh integration reliably.

# Save our ZDOTDIR before user scripts can overwrite it (e.g. user's .zshenv
# may contain "export ZDOTDIR=$HOME", which would prevent .zshrc from loading
# from the integration directory).
builtin typeset _termmesh_zdotdir="${ZDOTDIR}"

# Source the user's .zshenv (using $HOME, not ZDOTDIR, to avoid recursion).
{
    builtin typeset _termmesh_user_zshenv="${HOME}/.zshenv"
    [[ ! -r "$_termmesh_user_zshenv" ]] || builtin source -- "$_termmesh_user_zshenv"
} always {
    builtin unset _termmesh_user_zshenv
}

# Restore ZDOTDIR so subsequent dot-files (.zprofile, .zshrc) load from
# the integration directory, not from $HOME.
ZDOTDIR="${_termmesh_zdotdir}"
builtin unset _termmesh_zdotdir
