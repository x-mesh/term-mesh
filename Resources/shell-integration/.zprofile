# vim:ft=zsh
#
# ZDOTDIR wrapper: source the user's .zprofile from $HOME.
# ZDOTDIR stays pointing at integration dir (do not change it).

builtin typeset _termmesh_file="${HOME}/.zprofile"
[[ ! -r "$_termmesh_file" ]] || builtin source -- "$_termmesh_file"
builtin unset _termmesh_file
