# Interactive zsh init. See AGENTS.md - this file is the canonical source
# post-NixOS-migration; no /nix/store/... paths or nixos-rebuild aliases.

typeset -U path cdpath fpath manpath

# Prezto must be sourced before plugins that depend on its modules.
for _prezto_zshrc in \
  /usr/share/zsh-prezto/runcoms/zshrc \
  /opt/homebrew/opt/zsh-prezto/runcoms/zshrc \
  /usr/local/opt/zsh-prezto/runcoms/zshrc
do
  [ -r "$_prezto_zshrc" ] && source "$_prezto_zshrc" && break
done
unset _prezto_zshrc

# History
HISTSIZE=10000
SAVEHIST=10000
HISTFILE="$HOME/.zsh_history"
mkdir -p "$(dirname "$HISTFILE")"

set_opts=(
  HIST_FCNTL_LOCK HIST_IGNORE_DUPS HIST_IGNORE_SPACE SHARE_HISTORY
  NO_APPEND_HISTORY NO_EXTENDED_HISTORY NO_HIST_EXPIRE_DUPS_FIRST
  NO_HIST_FIND_NO_DUPS NO_HIST_IGNORE_ALL_DUPS NO_HIST_SAVE_NO_DUPS
)
for opt in "${set_opts[@]}"; do
  setopt "$opt"
done
unset opt set_opts

# zsh-autosuggestions (Arch: pacman zsh-autosuggestions; macOS: brew)
for _autosuggest in \
  /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh \
  /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
  /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh
do
  [ -r "$_autosuggest" ] && source "$_autosuggest" && break
done
unset _autosuggest
ZSH_AUTOSUGGEST_STRATEGY=(history)

# Optional integrations - guarded so missing tools don't break the shell.
command -v mise >/dev/null && eval "$(mise activate zsh)"
command -v direnv >/dev/null && eval "$(direnv hook zsh)"

export GPG_TTY=$TTY

# Conditional aliases - only when target tool exists.
command -v bat >/dev/null && alias cat=bat
if command -v eza >/dev/null; then
  alias ll='eza -l'
  alias ls=eza
fi

# zsh-syntax-highlighting must come last per upstream guidance.
for _highlight in \
  /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
  /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
  /usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
do
  [ -r "$_highlight" ] && source "$_highlight" && break
done
unset _highlight
ZSH_HIGHLIGHT_HIGHLIGHTERS=(main)
