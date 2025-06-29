#!/usr/bin/env zsh

set -xeuo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install Homebrew
if ! command -v brew &>/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> /Users/hyperlapse/.zprofile
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Install Homebrew formulae and casks
brew bundle --file="$DIR/Brewfile"

# Install prezto
git clone --recursive https://github.com/sorin-ionescu/prezto.git "${ZDOTDIR:-$HOME}/.zprezto"
git clone --recursive https://github.com/belak/prezto-contrib "${ZDOTDIR:-$HOME}/.zprezto/contrib"

MACOS_GHOSTTY_CONFIG="$HOME/Library/Application Support/com.mitchellh.ghostty/config"
if [ -f "$MACOS_GHOSTTY_CONFIG" ]; then
    rm "$MACOS_GHOSTTY_CONFIG"
fi

stow -t "$HOME" zsh git mise ghostty gnupg zed

# mise
mise trust --all && mise install
ln -s ~/.local/share/mise ~/.asdf
