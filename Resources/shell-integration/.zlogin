# vim:ft=zsh
#
# ZDOTDIR wrapper: source the user's .zlogin from $HOME.

builtin typeset _termmesh_zdotdir="${ZDOTDIR}"
builtin typeset _termmesh_file="${HOME}/.zlogin"
[[ ! -r "$_termmesh_file" ]] || builtin source -- "$_termmesh_file"
builtin unset _termmesh_file
ZDOTDIR="${_termmesh_zdotdir}"
builtin unset _termmesh_zdotdir
