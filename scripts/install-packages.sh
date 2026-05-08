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
  "${SUDO[@]}" dnf copr enable alternateved/keyd -y
  "${SUDO[@]}" dnf install fcitx5 fcitx5-hangul keyd dotnet-sdk-10.0 dotnet-sdk-8.0 ripgrep solaar solaar-udev -y
}

dotnet-tools() {
  dotnet tool install -g git-credential-manager \
    && dotnet tool install -g powershell
}

systemd() {
  "${SUDO[@]}" systemctl enable keyd
}

fedora
dotnet-tools
systemd
