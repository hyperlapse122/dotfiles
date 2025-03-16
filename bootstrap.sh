#!/usr/bin/env zsh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v brew &>/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> /Users/hyperlapse/.zprofile
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Install Homebrew formulae and casks
brew bundle --file="$DIR/Brewfile"

# Link mise configuration file and install it
mkdir -p "~/.config/mise" && ln -fs "$DIR/configurations/mise.toml" "$HOME/.config/mise/config.toml" && mise install

# Link git configuration file
ln -fs "$DIR/configurations/gitconfig" "$HOME/.gitconfig"
