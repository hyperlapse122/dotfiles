#
# Defines environment variables.
#
# Authors:
#   Sorin Ionescu <sorin.ionescu@gmail.com>
#

export DOTNET_ROOT="$HOME/.dotnet"

# Set the list of directories that Zsh searches for programs.
path=(
  $DOTNET_ROOT/tools(N)
  $HOME/.local/bin(N)
  $HOME/{,s}bin(N)
  /opt/{homebrew,local}/{,s}bin(N)
  /usr/local/{,s}bin(N)
  '/Applications/Visual Studio Code.app/Contents/Resources/app/bin'(N)
  $path
)

eval "$(mise activate zsh)"

# Ensure that a non-login, non-interactive shell has a defined environment.
if [[ ( "$SHLVL" -eq 1 && ! -o LOGIN ) && -s "${ZDOTDIR:-$HOME}/.zprofile" ]]; then
  source "${ZDOTDIR:-$HOME}/.zprofile"
fi
