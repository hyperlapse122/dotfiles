#!/usr/bin/env zsh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

brew bundle dump --no-go --no-vscode --no-cargo --mas --tap --cask --formulae -f --file="$DIR/Brewfile"
