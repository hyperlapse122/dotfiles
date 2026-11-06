[[ -o interactive ]] || return
(( ${+_DOTFILES_ZSH_INITIALIZED} )) && return
typeset -g _DOTFILES_ZSH_INITIALIZED=1
source "$ZDOTDIR/.zprezto/init.zsh"
if (( $+commands[mise] )); then
  eval "$(mise activate zsh)"
fi
