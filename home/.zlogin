# zsh login shell post-zshrc hook.
for _prezto_zlogin in \
  /usr/share/zsh-prezto/runcoms/zlogin \
  /opt/homebrew/opt/zsh-prezto/runcoms/zlogin \
  /usr/local/opt/zsh-prezto/runcoms/zlogin
do
  [ -r "$_prezto_zlogin" ] && source "$_prezto_zlogin" && break
done
unset _prezto_zlogin
