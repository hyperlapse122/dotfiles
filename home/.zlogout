# zsh logout hook.
for _prezto_zlogout in \
  /usr/share/zsh-prezto/runcoms/zlogout \
  /opt/homebrew/opt/zsh-prezto/runcoms/zlogout \
  /usr/local/opt/zsh-prezto/runcoms/zlogout
do
  [ -r "$_prezto_zlogout" ] && source "$_prezto_zlogout" && break
done
unset _prezto_zlogout
