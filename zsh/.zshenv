#
# Defines environment variables.
#
# Authors:
#   Sorin Ionescu <sorin.ionescu@gmail.com>
#

# Ensure that a non-login, non-interactive shell has a defined environment.
if [[ ( "$SHLVL" -eq 1 && ! -o LOGIN ) && -s "${ZDOTDIR:-$HOME}/.zprofile" ]]; then
  source "${ZDOTDIR:-$HOME}/.zprofile"
fi

# if $HOME/.local/bin is present add it to PATH
if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:${PATH}"
fi

# if $HOME/.dotnet/tools is present add it to PATH
if [ -d "$HOME/.dotnet/tools" ] ; then
    PATH="$HOME/.dotnet/tools:${PATH}"
fi

# if $HOME/.dotnet is present add it to PATH
if [ -d "$HOME/.dotnet" ] ; then
    DOTNET_HOME="$HOME/.dotnet"
    PATH="$DOTNET_HOME:${PATH}"
fi
