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
  # Install repository manager only when missing — dnf would otherwise hit the
  # network just to discover the package is already installed.
  if ! rpm -q fedora-workstation-repositories >/dev/null 2>&1; then
    "${SUDO[@]}" dnf install fedora-workstation-repositories -y
  fi

  # Enable third party repositories
  "${SUDO[@]}" fedora-third-party enable

  # Enable keyd COPR
  "${SUDO[@]}" dnf copr enable alternateved/keyd -y
  "${SUDO[@]}" dnf copr enable jdxcode/mise -y

  # Install RPM Fusion (free + nonfree) — skip the network install when both
  # release packages are already present. fedora-cisco-openh264 is enabled
  # unconditionally (setopt is idempotent) so steam/discord deps resolve.
  if ! rpm -q rpmfusion-free-release rpmfusion-nonfree-release >/dev/null 2>&1; then
    "${SUDO[@]}" dnf install -y \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
  fi
  "${SUDO[@]}" dnf config-manager setopt fedora-cisco-openh264.enabled=1

  # Install 1Password repository. Quoted heredoc keeps $basearch literal so
  # dnf substitutes it at install time (not at script-eval time).
  "${SUDO[@]}" rpm --import https://downloads.1password.com/linux/keys/1password.asc
  "${SUDO[@]}" tee /etc/yum.repos.d/1password.repo >/dev/null <<'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey="https://downloads.1password.com/linux/keys/1password.asc"
EOF

  # Install Visual Studio Code repository
  "${SUDO[@]}" rpm --import https://packages.microsoft.com/keys/microsoft.asc
  "${SUDO[@]}" tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

  # Install docker repository
  "${SUDO[@]}" dnf config-manager addrepo --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo --overwrite

  # Add Tailscale repository
  "${SUDO[@]}" dnf config-manager addrepo --from-repofile https://pkgs.tailscale.com/stable/fedora/tailscale.repo --overwrite

  # Install packages, grouped by purpose and alphabetised within each group.
  # steam/discord are bare-metal-only — systemd-detect-virt exits 0 when
  # virtualization is detected, 1 on bare metal.
  "${SUDO[@]}" dnf group install development-tools -y
  local -a packages=(
    # Build tooling
    gcc-c++
    pkg-config

    # CLI utilities
    btop
    gh
    ripgrep
    yp-tools

    # Korean input method
    fcitx5
    fcitx5-hangul

    # Keyboard remapper
    keyd

    # Language toolchains + version manager
    dotnet-sdk-10.0
    dotnet-sdk-8.0
    mise

    # Logitech device manager
    solaar
    solaar-udev

    # Password manager
    1password
    1password-cli

    # Editor
    code

    # Container runtime (Docker CE + plugins)
    containerd.io
    docker-buildx-plugin
    docker-ce
    docker-ce-cli
    docker-compose-plugin

    # Browser
    google-chrome-stable

    # Mesh networking / VPN
    tailscale
  )
  if ! systemd-detect-virt --quiet; then
    # Bare-metal-only: games + chat (both via RPM Fusion nonfree)
    packages+=(
      discord
      steam
    )
  fi
  "${SUDO[@]}" dnf install -y "${packages[@]}"
}

dotnet-tools() {
  dotnet tool install -g git-credential-manager
  dotnet tool install -g powershell
}

systemd() {
  "${SUDO[@]}" systemctl enable --now keyd
  "${SUDO[@]}" systemctl enable --now docker
  "${SUDO[@]}" systemctl enable --now tailscaled
}

user-groups() {
  "${SUDO[@]}" usermod -aG docker,keyd "$USER"

  # Group changes only take effect on next login. Notify when the current
  # shell is missing either group — silent on re-runs after re-login.
  if ! id -nG | grep -qw docker || ! id -nG | grep -qw keyd; then
    printf '\n'
    printf 'NOTE: Added "%s" to groups: docker, keyd\n' "$USER"
    printf '      Log out and back in (or reboot) for group membership to take effect.\n'
  fi
}

fedora
dotnet-tools
systemd
user-groups
