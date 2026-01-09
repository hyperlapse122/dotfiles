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

cd yay
makepkg -si --noconfirm
cd ..
rm -rf yay

# Configure yay once to always skip menus / questions
yay --save \
  --answerdiff None \
  --answeredit None \
  --answerclean None

# Non-interactive yay install of all required packages
yay -S --needed --noconfirm --mflags "--noconfirm" \
  1password 1password-cli rust cargo qt5-base qt6-base mise kime-git visual-studio-code-bin \
  google-chrome \
  otf-pretendard-jp otf-pretendard-std ttf-pretendard-gov ttf-pretendard-jp ttf-pretendard-std \
  otf-pretendard ttf-pretendard otf-pretendard-gov

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
