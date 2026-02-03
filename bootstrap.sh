#!/usr/bin/env zsh

set -xeuo pipefail

_OS=$(uname)

if [[ "$_OS" == "Darwin" ]]; then
  # Install Homebrew
  if ! command -v brew &>/dev/null; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # shellcheck disable=SC2016
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi

  if ! command -v git &>/dev/null; then
    brew install git git-lfs
  fi
fi

# Clone the repo then it's not cloned yet
if [ ! -d "${ZDOTDIR:-$HOME}/.dotfiles" ]; then
  git clone --recursive https://github.com/hyperlapse122/dotfiles.git "${ZDOTDIR:-$HOME}/.dotfiles"
fi

cd "${ZDOTDIR:-$HOME}/.dotfiles" && source install.sh
