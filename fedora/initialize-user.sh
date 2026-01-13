#!/bin/bash

set -e -o pipefail

# Set IME to kime
kwriteconfig6 --file kwinrc --group Wayland --key InputMethod /usr/share/applications/kime.desktop

# Clone dotfiles and run install non-interactively
cd ~
if [ ! -d dotfiles ]; then
  git clone https://github.com/hyperlapse122/dotfiles
fi

cd dotfiles
mise trust --all
sh ./install.sh

# Change shell non-interactively
chsh -s "$(command -v zsh)"

cd "$_PWD"
