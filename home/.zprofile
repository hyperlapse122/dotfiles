#
# Executes commands at login pre-zshrc.
#
# Authors:
#   Sorin Ionescu <sorin.ionescu@gmail.com>
#

#
# Browser
#

if [[ -z "$BROWSER" && "$OSTYPE" == darwin* ]]; then
  export BROWSER='open'
fi

#
# Editors
#

if [[ -z "$EDITOR" ]]; then
  export EDITOR='nano'
fi
if [[ -z "$VISUAL" ]]; then
  export VISUAL='nano'
fi
if [[ -z "$PAGER" ]]; then
  export PAGER='less'
fi

#
# Language
#

if [[ -z "$LANG" ]]; then
  export LANG='en_US.UTF-8'
fi

#
# Paths
#

# Ensure path arrays do not contain duplicates.
typeset -gU cdpath fpath mailpath path

# Set the list of directories that cd searches.
# cdpath=(
#   $cdpath
# )

# Set the list of directories that Zsh searches for programs.
path=(
  $HOME/{,s}bin(N)
  /opt/{homebrew,local}/{,s}bin(N)
  /usr/local/{,s}bin(N)
  $path
)

#
# Less
#

# Set the default Less options.
# Mouse-wheel scrolling has been disabled by -X (disable screen clearing).
# Remove -X to enable it.
if [[ -z "$LESS" ]]; then
  export LESS='-g -i -M -R -S -w -X -z-4'
fi

# Set the Less input preprocessor.
# Try both `lesspipe` and `lesspipe.sh` as either might exist on a system.
if [[ -z "$LESSOPEN" ]] && (( $#commands[(i)lesspipe(|.sh)] )); then
  export LESSOPEN="| /usr/bin/env $commands[(i)lesspipe(|.sh)] %s 2>&-"
fi

# Get OS information
os=$(uname)

# Configure macOS settings
if [[ "$os" == "Darwin" ]]; then
  # Homebrew
  eval "$(brew shellenv)"
fi

DOTNET_ROOT="$HOME/.dotnet"
PATH="$DOTNET_ROOT:$HOME/.dotnet/tools:$HOME/.local/bin:${PATH}"

eval "$(mise activate zsh)"

# JetBrains Toolbox
JETBRAINS_TOOLBOX_HOME="$HOME/Library/Application Support/JetBrains/Toolbox/scripts"
if [ -d $JETBRAINS_TOOLBOX_HOME ]; then
  export JETBRAINS_TOOLBOX_HOME
  export PATH="$PATH:$JETBRAINS_TOOLBOX_HOME"
fi

# Android SDK
ANDROID_HOME=$HOME/Library/Android/sdk
if [ -d $ANDROID_HOME ]; then
  export ANDROID_HOME
  export PATH=$PATH:$ANDROID_HOME/emulator
  export PATH=$PATH:$ANDROID_HOME/platform-tools
fi

# OrbStack
ORBSTACK_SHELL_INIT="$HOME/.orbstack/shell/init.zsh"
if [ -f "$ORBSTACK_SHELL_INIT" ]; then
  source "ORBSTACK_SHELL_INIT" 2>/dev/null || :
fi
