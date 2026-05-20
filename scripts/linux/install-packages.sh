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
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "$TARGET_HOME" ]]; then
  printf 'install-packages.sh: could not resolve home directory for %s.\n' "$TARGET_USER" >&2
  exit 1
fi

source_os_release() {
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_ID_LIKE=" ${ID_LIKE:-} "
  OS_VERSION_ID="${VERSION_ID:-}"
  RHEL_MAJOR="$(rpm -E '%{rhel}' 2>/dev/null || true)"
}

package_available() {
  dnf -q list --available "$1" >/dev/null 2>&1 || dnf -q list --installed "$1" >/dev/null 2>&1
}

install_available_packages() {
  local -a requested=("$@")
  local -a available=()
  local -a skipped=()

  for package in "${requested[@]}"; do
    if package_available "$package"; then
      available+=("$package")
    else
      skipped+=("$package")
    fi
  done

  if ((${#available[@]})); then
    "${SUDO[@]}" dnf install -y "${available[@]}"
  fi

  if ((${#skipped[@]})); then
    printf '\n'
    printf 'install-packages.sh: skipped unavailable packages: %s\n' "${skipped[*]}"
  fi
}

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
    # Bare-metal-only
    packages+=(
      discord
      steam
      lm_sensors
    )
  fi
  "${SUDO[@]}" dnf install -y "${packages[@]}"
}

rocky_or_rhel() {
  local major="${RHEL_MAJOR:-10}"

  # EPEL + CRB cover most CLI/dev packages on Rocky/RHEL. Both operations are
  # idempotent; epel-release is already present on some provisioned hosts.
  if ! rpm -q epel-release >/dev/null 2>&1; then
    "${SUDO[@]}" dnf install -y epel-release
  fi
  "${SUDO[@]}" dnf config-manager --set-enabled crb || true

  # Enable mise COPR when available for this EL release. keyd's COPR currently
  # has no EPEL 10 build, so keyd remains an optional package below.
  "${SUDO[@]}" dnf copr enable jdxcode/mise -y || true

  # Third-party repositories used by the shared package list.
  "${SUDO[@]}" rpm --import https://downloads.1password.com/linux/keys/1password.asc
  "${SUDO[@]}" tee /etc/yum.repos.d/1password.repo >/dev/null <<'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey="https://downloads.1password.com/linux/keys/1password.asc"
EOF

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

  "${SUDO[@]}" rpm --import https://dl.google.com/linux/linux_signing_key.pub
  "${SUDO[@]}" tee /etc/yum.repos.d/google-chrome.repo >/dev/null <<'EOF'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/$basearch
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF

  "${SUDO[@]}" dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
  "${SUDO[@]}" rpm --import "https://pkgs.tailscale.com/stable/rhel/${major}/repo.gpg"
  "${SUDO[@]}" dnf config-manager --add-repo "https://pkgs.tailscale.com/stable/rhel/${major}/tailscale.repo"
  # DNF on EL 10 can repeatedly prompt for the repo metadata key even after rpm
  # import. Keep package GPG checks on, but disable repo metadata GPG checks.
  "${SUDO[@]}" sed -i 's/^repo_gpgcheck=1/repo_gpgcheck=0/' /etc/yum.repos.d/tailscale*.repo

  "${SUDO[@]}" dnf makecache --refresh -y
  "${SUDO[@]}" dnf group install "Development Tools" -y

  local -a packages=(
    # Build tooling
    gcc-c++
    pkgconf-pkg-config

    # CLI utilities
    btop
    gh
    ripgrep
    yp-tools

    # Korean input method / hardware tooling. These are not available on every
    # EL release yet, so install_available_packages skips missing packages.
    fcitx5
    fcitx5-hangul
    keyd
    solaar
    solaar-udev

    # Language toolchains + version manager
    dotnet-sdk-10.0
    dotnet-sdk-8.0
    mise

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
    packages+=(
      discord
      steam
      lm_sensors
    )
  fi
  install_available_packages "${packages[@]}"
}

dotnet-tools() {
  local tool
  for tool in git-credential-manager powershell; do
    if HOME="$TARGET_HOME" dotnet tool list -g | awk '{print $1}' | grep -qx "$tool"; then
      HOME="$TARGET_HOME" dotnet tool update -g "$tool"
    else
      HOME="$TARGET_HOME" dotnet tool install -g "$tool"
    fi
  done
}

systemd() {
  local service
  for service in keyd docker tailscaled; do
    if systemctl list-unit-files "${service}.service" >/dev/null 2>&1; then
      "${SUDO[@]}" systemctl enable --now "$service"
    else
      printf 'install-packages.sh: skipped missing service: %s\n' "$service"
    fi
  done
}

user-groups() {
  local -a groups=()
  getent group docker >/dev/null && groups+=(docker)
  getent group keyd >/dev/null && groups+=(keyd)

  if ((${#groups[@]})); then
    local joined
    joined="$(IFS=,; printf '%s' "${groups[*]}")"
    "${SUDO[@]}" usermod -aG "$joined" "$TARGET_USER"
  fi

  # Group changes only take effect on next login. Notify when the current
  # shell is missing either group — silent on re-runs after re-login.
  if ((${#groups[@]})) && ! id -nG "$TARGET_USER" | grep -Eqw "$(IFS='|'; printf '%s' "${groups[*]}")"; then
    printf '\n'
    printf 'NOTE: Added "%s" to groups: %s\n' "$TARGET_USER" "${groups[*]}"
    printf '      Log out and back in (or reboot) for group membership to take effect.\n'
  fi
}

source_os_release
case "$OS_ID:$OS_ID_LIKE" in
  fedora:*)
    fedora
    ;;
  rocky:*|rhel:*|almalinux:*|centos:*|*" rhel "*|*" fedora "*)
    rocky_or_rhel
    ;;
  *)
    printf 'install-packages.sh: unsupported Linux distribution: %s\n' "$OS_ID" >&2
    exit 1
    ;;
esac
dotnet-tools
systemd
user-groups
