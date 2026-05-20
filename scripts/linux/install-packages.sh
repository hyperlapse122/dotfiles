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
  "${SUDO[@]}" dnf group install development-tools virtualization -y
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

    # Ruby build dependencies (consumed by mise's ruby-build).
    # The runtime libs libffi/libyaml are pulled in transitively.
    libffi-devel
    libyaml-devel

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

    # Virtualization
    virtualbox
    akmods
  )
  if ! systemd-detect-virt --quiet; then
    # Bare-metal-only
    packages+=(
      discord
      steam
      lm_sensors
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
  "${SUDO[@]}" systemctl enable --now libvirtd.service
  
  # this may fail until the user reboots to load the vboxdrv kernel module, but enable it anyway so it starts on next boot
  "${SUDO[@]}" systemctl enable vboxdrv

  # Sign all kernel modules
  "${SUDO[@]}" systemctl start akmods.service

  # Import the akmods MOK signing key. Skipped unless ALL of:
  #   1. Booted via UEFI with Secure Boot enabled — otherwise unsigned
  #      modules load fine and `mokutil --import` would queue a pointless
  #      MOK enrollment prompt on next boot.
  #   2. akmods generated the public key (akmods.service writes it on
  #      first run; bare-metal-only on systems where signing is configured).
  #   3. The key isn't already enrolled (mokutil --test-key returns "is
  #      already enrolled") and isn't already queued in --list-new for
  #      enrollment on next boot — re-importing prompts the user for a
  #      fresh one-time password and replaces the pending request.
  local pubkey=/etc/pki/akmods/certs/public_key.der
  local fp
  if [[ ! -d /sys/firmware/efi ]]; then
    printf 'install-packages.sh: not booted via UEFI; skipping akmods MOK import.\n'
  elif ! mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
    printf 'install-packages.sh: Secure Boot disabled; skipping akmods MOK import.\n'
  elif [[ ! -f "${pubkey}" ]]; then
    printf 'install-packages.sh: %s missing; skipping akmods MOK import.\n' "${pubkey}"
  elif mokutil --test-key "${pubkey}" 2>/dev/null | grep -q 'is already enrolled'; then
    printf 'install-packages.sh: akmods MOK already enrolled; skipping import.\n'
  elif fp="$(openssl x509 -in "${pubkey}" -inform DER -noout -fingerprint -sha1 2>/dev/null | sed 's/.*=//')" \
       && [[ -n "${fp}" ]] \
       && mokutil --list-new 2>/dev/null | grep -qi "${fp}"; then
    printf 'install-packages.sh: akmods MOK already queued for enrollment on next boot; skipping import.\n'
  else
    "${SUDO[@]}" mokutil --import "${pubkey}"
  fi
}

user-groups() {
  "${SUDO[@]}" usermod -aG docker,keyd,libvirt "$USER"

  # Group changes only take effect on next login. Notify when the current
  # shell is missing either group — silent on re-runs after re-login.
  if ! id -nG | grep -qw docker || ! id -nG | grep -qw keyd || ! id -nG | grep -qw libvirt; then
    printf '\n'
    printf 'NOTE: Added "%s" to groups: docker, keyd, libvirt\n' "$USER"
    printf '      Log out and back in (or reboot) for group membership to take effect.\n'
  fi
}

fedora
dotnet-tools
systemd
user-groups
