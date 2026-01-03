#!/bin/bash

set -e -o pipefail

_PWD=$(pwd)

cd ~ \
  && sudo pacman -S --needed git base-devel \
  && git clone https://aur.archlinux.org/yay.git \
  && cd yay \
  && makepkg -si \
  && cd .. \
  && rm -rf yay

yay -S 1password 1password-cli rust cargo qt5-base qt6-base git git-lfs mise kime-git visual-studio-code-bin gnupg zsh \
  otf-pretendard-jp otf-pretendard-std ttf-pretendard-gov ttf-pretendard-jp ttf-pretendard-std otf-pretendard ttf-pretendard otf-pretendard-gov \
  ttf-jetbrains-mono ttf-jetbrains-mono-nerd

cd ~ \
  && git clone https://github.com/hyperlapse122/dotfiles \
  && cd dotfiles \
  && mise trust --all \
  && sh ./install.sh

chsh -s $(which zsh)

cd $_PWD
