typeset -U path cdpath fpath manpath
for profile in ${(z)NIX_PROFILES}; do
  fpath+=($profile/share/zsh/site-functions $profile/share/zsh/$ZSH_VERSION/functions $profile/share/zsh/vendor-completions)
done

HELPDIR="/nix/store/pbr67bz9gw0by9sz5rb3wgncp6hv4b8y-zsh-5.9/share/zsh/$ZSH_VERSION/help"

source /nix/store/pmr5cr37y4pfzfpssz7dqnjkgyhxk37m-zsh-autosuggestions-0.7.1/share/zsh-autosuggestions/zsh-autosuggestions.zsh
ZSH_AUTOSUGGEST_STRATEGY=(history)


# Load prezto
source /nix/store/d3m4ppwxkf8ql7zglrwdmw3mx1s8zzjd-zsh-prezto-0-unstable-2025-07-30/share/zsh-prezto/runcoms/zshrc

# History options should be set in .zshrc and after oh-my-zsh sourcing.
# See https://github.com/nix-community/home-manager/issues/177.
HISTSIZE="10000"
SAVEHIST="10000"

HISTFILE="/home/h82/.zsh_history"
mkdir -p "$(dirname "$HISTFILE")"

# Set shell options
set_opts=(
  HIST_FCNTL_LOCK HIST_IGNORE_DUPS HIST_IGNORE_SPACE SHARE_HISTORY
  NO_APPEND_HISTORY NO_EXTENDED_HISTORY NO_HIST_EXPIRE_DUPS_FIRST
  NO_HIST_FIND_NO_DUPS NO_HIST_IGNORE_ALL_DUPS NO_HIST_SAVE_NO_DUPS
)
for opt in "${set_opts[@]}"; do
  setopt "$opt"
done
unset opt set_opts

# Activate mise so PATH and the chpwd hook for directory-based version
# switching are set up in interactive zsh sessions. Done explicitly here
# (instead of relying on programs.mise.enableZshIntegration) so the
# snippet has a known position in .zshrc and is visible in this file.
eval "$(/nix/store/w164w1qscqmyszrgxz21j7digl6pkxm4-mise-2026.4.20/bin/mise activate zsh)"

rebuild() {
  sudo nixos-rebuild switch --flake ~/nix-config "$@"
}

rebuild-test() {
  sudo nixos-rebuild test --flake ~/nix-config "$@"
}

rebuild-boot() {
  sudo nixos-rebuild boot --flake ~/nix-config "$@"
}

eval "$(/nix/store/vcbik2fsll4m4zr870px0yn27fj54ap7-direnv-2.37.1/bin/direnv hook zsh)"

export GPG_TTY=$TTY

alias -- cat=bat
alias -- gc-all='sudo nix-collect-garbage -d'
alias -- ll='eza -l'
alias -- ls=eza
source /nix/store/7kfw9rxjcaymdn7xhczxx6valclc9nxp-zsh-syntax-highlighting-0.8.0/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
ZSH_HIGHLIGHT_HIGHLIGHTERS=(main)


