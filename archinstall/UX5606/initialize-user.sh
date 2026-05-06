#!/bin/bash

set -e -o pipefail

_PWD=$(pwd)

# Ensure git + base-devel non-interactively
cd ~
sudo pacman -S --needed --noconfirm git base-devel

# Clone and build yay non-interactively
if [ ! -d yay ]; then
  git clone https://aur.archlinux.org/yay.git
fi

cd yay && \
  makepkg -si --noconfirm && \
  cd .. && \
  rm -rf yay

# Non-interactive yay install of all required packages
LANG=C yay --answerdiff None --answerclean None --mflags "--noconfirm" -S --needed \
  1password 1password-cli visual-studio-code-bin \
  google-chrome zenity ffmpeg4.4 \
  otf-pretendard-jp otf-pretendard-std ttf-pretendard-gov ttf-pretendard-jp ttf-pretendard-std \
  otf-pretendard ttf-pretendard otf-pretendard-gov

kwriteconfig6 --file kwinrc --group Wayland --key InputMethod /usr/share/applications/fcitx5-wayland-launcher.desktop

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
