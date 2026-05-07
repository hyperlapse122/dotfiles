# zsh environment, sourced for all zsh invocations.
# Cross-platform: graceful fallback when zsh-prezto isn't installed
# (e.g. before yay -S zsh-prezto on Arch, or before brew install on macOS).
for _prezto_zshenv in \
  /usr/share/zsh-prezto/runcoms/zshenv \
  /opt/homebrew/opt/zsh-prezto/runcoms/zshenv \
  /usr/local/opt/zsh-prezto/runcoms/zshenv
do
  [ -r "$_prezto_zshenv" ] && source "$_prezto_zshenv" && break
done
unset _prezto_zshenv
