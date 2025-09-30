#!/usr/bin/env zsh

set -xeuo pipefail

os=$(uname)
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configure macOS settings
if [[ "$os" == "Darwin" ]]; then
  source macos/configure.sh
fi

# Install Homebrew formulae and casks
brew bundle --file="$DIR/Brewfile"

# Install prezto when it's not installed
if [ ! -d "${ZDOTDIR:-$HOME}/.zprezto" ]; then
  git clone --recursive https://github.com/sorin-ionescu/prezto.git "${ZDOTDIR:-$HOME}/.zprezto"
  git clone --recursive https://github.com/belak/prezto-contrib "${ZDOTDIR:-$HOME}/.zprezto/contrib"
fi

MACOS_GHOSTTY_CONFIG="$HOME/Library/Application Support/com.mitchellh.ghostty/config"
if [ -f "$MACOS_GHOSTTY_CONFIG" ]; then
    rm "$MACOS_GHOSTTY_CONFIG"
fi

stow -t "$HOME" zsh git mise ghostty gnupg zed

# mise
mise trust --all && mise install

# Symlink mise to asdf for JetBrains IDEs
ln -s ~/.local/share/mise ~/.asdf
