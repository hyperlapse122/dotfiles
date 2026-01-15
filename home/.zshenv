#
# Defines environment variables.
#
# Authors:
#   Sorin Ionescu <sorin.ionescu@gmail.com>
#

eval "$(mise activate zsh)"

export DOTNET_ROOT="$HOME/.dotnet"
PATH="$DOTNET_ROOT:$DOTNET_ROOT/tools:$HOME/.local/bin:${PATH}"

# Ensure that a non-login, non-interactive shell has a defined environment.
if [[ ( "$SHLVL" -eq 1 && ! -o LOGIN ) && -s "${ZDOTDIR:-$HOME}/.zprofile" ]]; then
  source "${ZDOTDIR:-$HOME}/.zprofile"
fi
