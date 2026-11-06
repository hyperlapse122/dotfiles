zstyle ':prezto:*:*' color 'yes'
zstyle ':prezto:module:editor' key-bindings 'emacs'
zstyle ':prezto:module:prompt' theme 'sorin'

typeset -a _dotfiles_modules
_dotfiles_modules=(environment terminal editor history directory spectrum utility)
(( $+commands[git] )) && _dotfiles_modules+=(git)
[[ $OSTYPE == darwin* ]] && (( $+commands[brew] )) && _dotfiles_modules+=(homebrew)

# Prezto's GPG module can otherwise replace an existing SSH-agent environment.
if (( $+commands[gpg-agent] )); then
  if ! grep -Eq '^[[:space:]]*enable-ssh-support([[:space:]]|$)' "${GNUPGHOME:-$HOME/.gnupg}/gpg-agent.conf" 2>/dev/null \
      && ! grep -Eq 'SSH_AUTH_SOCK|SSH_AGENT_PID' "${XDG_CACHE_HOME:-$HOME/.cache}/prezto/gpg-agent.env" 2>/dev/null; then
    _dotfiles_modules+=(gpg)
  fi
  [[ -z $TTY ]] || export GPG_TTY=$TTY
fi
_dotfiles_modules+=(completion syntax-highlighting history-substring-search autosuggestions prompt)
zstyle ':prezto:load' pmodule "$_dotfiles_modules[@]"
unset _dotfiles_modules
