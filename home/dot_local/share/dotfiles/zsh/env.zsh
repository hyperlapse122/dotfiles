export NODE_USE_SYSTEM_CA=1
typeset -U path
path=("$HOME/.local/share/dotfiles/zsh/bin" "$HOME/.local/bin" $path)
export PATH
if [[ -o interactive ]]; then
  typeset -U fpath
  fpath=("$HOME/.local/share/dotfiles/zsh/completions" $fpath)
fi
