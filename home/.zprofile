# zsh login shell profile. See AGENTS.md for the migration rationale.
for _prezto_zprofile in \
  /usr/share/zsh-prezto/runcoms/zprofile \
  /opt/homebrew/opt/zsh-prezto/runcoms/zprofile \
  /usr/local/opt/zsh-prezto/runcoms/zprofile
do
  [ -r "$_prezto_zprofile" ] && source "$_prezto_zprofile" && break
done
unset _prezto_zprofile
