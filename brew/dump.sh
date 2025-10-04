#!/usr/bin/env zsh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

brew bundle dump -f --file="$DIR/Brewfile"
