#!/bin/bash

set -e -o pipefail

# Enable kime(IME) copr
dnf copr enable -y toroidalfox/kime

# Enable mise copr
dnf copr enable -y jdxcode/mise

# Enable keyd copr
dnf copr enable alternateved/keyd

# Add Docker repository
dnf config-manager addrepo --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo

# Add 1Password
rpm --import https://downloads.1password.com/linux/keys/1password.asc
sh -c 'echo -e "[1password]\nname=1Password Stable Channel\nbaseurl=https://downloads.1password.com/linux/rpm/stable/\$basearch\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=\"https://downloads.1password.com/linux/keys/1password.asc\"" > /etc/yum.repos.d/1password.repo'

# Add Visual Studio Code
rpm --import https://packages.microsoft.com/keys/microsoft.asc
echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\nautorefresh=1\ntype=rpm-md\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" | tee /etc/yum.repos.d/vscode.repo > /dev/null

# Install Packages
dnf install -y kime 1password 1password-cli mise zsh code keyd docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm

# Enable services
systemctl enable --now keyd
systemctl enable --now docker
systemctl enable --now containerd.service

# Add user to docker group
usermod -aG docker $USER
