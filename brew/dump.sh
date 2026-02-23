#!/bin/sh

_CURR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_CURR_DIR" || exit 1

brew bundle dump --no-go --no-vscode --no-cargo --mas --tap --cask --formulae -f --file="-" > "$_CURR_DIR/Brewfile"
