#!/bin/sh

_CURR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_CURR_DIR" || exit 1

code --list-extensions > "$_CURR_DIR/extensions.txt"
