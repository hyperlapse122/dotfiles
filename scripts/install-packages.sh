#!/usr/bin/env bash

set -euo pipefail

# Use sudo only when not already root (matches install-linux-system-config.sh).
# Throw early if neither root nor sudo is available — dnf/systemctl need it.
if [[ "${EUID}" -eq 0 ]]; then
  SUDO=()
elif command -v sudo >/dev/null 2>&1; then
  SUDO=(sudo)
else
  printf 'install-packages.sh: requires root or sudo for package installation.\n' >&2
  exit 1
fi

fedora() {
  # Install repository manager
  "${SUDO[@]}" dnf install fedora-workstation-repositories -y

  # Enable third party repositories
  "${SUDO[@]}" fedora-third-party enable

  # Enable keyd COPR
  "${SUDO[@]}" dnf copr enable alternateved/keyd -y
  "${SUDO[@]}" dnf copr enable jdxcode/mise -y

  # Install RPMFusion and set fedora-cisco-openh264.enabled to 1 for steam and discord
  # TODO: Skip RPM Fusion installation when the package is already installed
  "${SUDO[@]}" dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm -y
  "${SUDO[@]}" dnf config-manager setopt fedora-cisco-openh264.enabled=1

  # Install 1Password repository
  "${SUDO[@]}" rpm --import https://downloads.1password.com/linux/keys/1password.asc
  "${SUDO[@]}" sh -c 'echo -e "[1password]\nname=1Password Stable Channel\nbaseurl=https://downloads.1password.com/linux/rpm/stable/\$basearch\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=\"https://downloads.1password.com/linux/keys/1password.asc\"" > /etc/yum.repos.d/1password.repo'

  # Install Visual Studio Code repository
  "${SUDO[@]}" rpm --import https://packages.microsoft.com/keys/microsoft.asc
  echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\nautorefresh=1\ntype=rpm-md\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" | "${SUDO[@]}" tee /etc/yum.repos.d/vscode.repo > /dev/null

  # Install docker repository
  "${SUDO[@]}" dnf config-manager addrepo --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo --overwrite

  # Install packages
  "${SUDO[@]}" dnf group install development-tools -y
  "${SUDO[@]}" dnf install pkg-config \
    fcitx5 fcitx5-hangul keyd \
    dotnet-sdk-10.0 dotnet-sdk-8.0 \
    ripgrep solaar solaar-udev 1password 1password-cli mise code \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    google-chrome-stable gh -y

  # TODO: install steam and discord for non-vm
}

dotnet-tools() {
  dotnet tool install -g git-credential-manager \
    && dotnet tool install -g powershell
}

systemd() {
  "${SUDO[@]}" systemctl enable keyd
  "${SUDO[@]}" systemctl enable --now docker
}

user-groups() {
  "${SUDO[@]}" usermod -aG docker,keyd "$USER"
}

fedora
dotnet-tools
systemd
user-groups
