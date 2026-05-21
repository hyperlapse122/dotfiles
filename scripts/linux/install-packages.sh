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
    akmod-VirtualBox
    kernel-devel
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

akmods() {
  "${SUDO[@]}" akmods
}

virtualbox-extension-pack() {
  if ! command -v VBoxManage >/dev/null 2>&1; then
    printf 'install-packages.sh: VBoxManage not installed; skipping extension pack.\n'
    return 0
  fi

  # VBoxManage --version emits e.g. "7.2.8_RPMFUSIONr173730" (RPM Fusion build)
  # or "7.2.8r166737" (upstream). Strip from the first non-version character
  # to recover "7.2.8", which is what download.virtualbox.org publishes the
  # matching extpack under.
  local vbox_version installed_version pack_file base_url
  vbox_version="$(VBoxManage --version 2>/dev/null | awk -F_ '/^[0-9]+\.[0-9]+\.[0-9]+_/ {print $1}')"
  if [[ -z "${vbox_version}" ]]; then
    printf 'install-packages.sh: could not parse VirtualBox version; skipping extension pack.\n' >&2
    return 1
  fi

  # Skip if the installed extpack already matches the running VirtualBox.
  installed_version="$(VBoxManage list extpacks 2>/dev/null \
    | awk '/^Pack no\. 0:/{found=1} found && /^Version:/{print $2; exit}')"
  if [[ "${installed_version}" == "${vbox_version}" ]]; then
    printf 'install-packages.sh: VirtualBox Extension Pack %s already installed; skipping.\n' "${vbox_version}"
    return 0
  fi

  pack_file="Oracle_VirtualBox_Extension_Pack-${vbox_version}.vbox-extpack"
  base_url="https://download.virtualbox.org/virtualbox/${vbox_version}"

  # Subshell scopes the EXIT trap so the tmpdir is cleaned up whether the
  # work succeeds or fails under set -e, without leaking a RETURN trap
  # into subsequent functions.
  (
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "${tmpdir}"' EXIT

    curl -fsSL -o "${tmpdir}/${pack_file}" "${base_url}/${pack_file}"
    curl -fsSL -o "${tmpdir}/SHA256SUMS"   "${base_url}/SHA256SUMS"

    # SHA256SUMS lines are "<sha256> *<filename>". Pull the line for our exact
    # filename; refuse to proceed if it is missing (sha256sum -c on empty
    # stdin exits 0, which would silently skip verification).
    cd "${tmpdir}"
    expected="$(awk -v f="*${pack_file}" '$2 == f' SHA256SUMS)"
    if [[ -z "${expected}" ]]; then
      printf 'install-packages.sh: %s missing from upstream SHA256SUMS; aborting.\n' "${pack_file}" >&2
      exit 1
    fi
    printf '%s\n' "${expected}" | sha256sum -c -

    # VBoxManage accepts --accept-license=<sha256 of bundled
    # ExtPack-license.txt> for non-interactive install. Compute it from the
    # verified archive so a future license change is picked up automatically.
    license_hash="$(tar -xOzf "${pack_file}" ./ExtPack-license.txt | sha256sum | awk '{print $1}')"

    "${SUDO[@]}" VBoxManage extpack install --replace \
      --accept-license="${license_hash}" "${tmpdir}/${pack_file}"
  )

  # A user-owned VBoxSVC started before this install caches "no extpacks"
  # in-process; without restarting it the user keeps seeing the pre-install
  # list until next login. See https://www.virtualbox.org/ticket/17034.
  local target_user="${SUDO_USER:-$USER}"
  if [[ -n "${target_user}" && "${target_user}" != "root" ]]; then
    pkill -u "${target_user}" -x VBoxSVC 2>/dev/null || true
  fi
}

systemd() {
  "${SUDO[@]}" systemctl enable --now keyd
  "${SUDO[@]}" systemctl enable --now docker
  "${SUDO[@]}" systemctl enable --now tailscaled
  "${SUDO[@]}" systemctl enable --now libvirtd.service
  
  # this may fail until the user reboots to load the vboxdrv kernel module, but enable it anyway so it starts on next boot
  "${SUDO[@]}" systemctl enable vboxdrv

  # Enabling akmods.service ensures kernel modules are automatically signed and loaded
  "${SUDO[@]}" systemctl enable --now akmods.service

  # Import every akmods MOK signing key under /etc/pki/akmods/certs/ for
  # any out-of-tree kernel modules built by akmods (currently virtualbox).
  # Skipped entirely unless booted via UEFI with Secure Boot enabled —
  # otherwise unsigned modules load fine and `mokutil --import` would
  # queue a pointless MOK Manager prompt on next boot.
  #
  # /etc/pki/akmods/certs/ is mode 0750 root:akmods, so every read of the
  # directory and its contents (listing, existence check, mokutil
  # --test-key, openssl fingerprint) goes through sudo — a normal user
  # cannot see files in there even though only --import strictly needs
  # root. Per-cert enrollment check uses `mokutil --test-key` (which
  # confusingly exits 1 when the key IS enrolled, so we grep its stdout
  # for "is already enrolled") and a pending-enrollment check against
  # `mokutil --list-new` by SHA1 fingerprint so re-runs between import
  # and reboot don't re-prompt for the one-time password and replace
  # the pending request. Approved-to-import certs are batched into a
  # single `mokutil --import` call so the user enters the one-time
  # password once for all of them.
  if [[ ! -d /sys/firmware/efi ]]; then
    printf 'install-packages.sh: not booted via UEFI; skipping akmods MOK import.\n'
  elif ! mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
    printf 'install-packages.sh: Secure Boot disabled; skipping akmods MOK import.\n'
  elif ! "${SUDO[@]}" test -d /etc/pki/akmods/certs; then
    printf 'install-packages.sh: /etc/pki/akmods/certs missing; skipping akmods MOK import.\n'
  else
    local -a certs=() to_import=()
    local cert fp
    readarray -t certs < <("${SUDO[@]}" find /etc/pki/akmods/certs -maxdepth 1 -type f -name '*.der' -print | sort)
    if [[ ${#certs[@]} -eq 0 ]]; then
      printf 'install-packages.sh: no .der certs in /etc/pki/akmods/certs; skipping akmods MOK import.\n'
    else
      for cert in "${certs[@]}"; do
        if "${SUDO[@]}" mokutil --test-key "${cert}" 2>/dev/null | grep -q 'is already enrolled'; then
          printf 'install-packages.sh: %s already enrolled; skipping.\n' "${cert}"
          continue
        fi
        fp="$("${SUDO[@]}" openssl x509 -in "${cert}" -inform DER -noout -fingerprint -sha1 2>/dev/null | sed 's/.*=//')"
        if [[ -n "${fp}" ]] && mokutil --list-new 2>/dev/null | grep -qi "${fp}"; then
          printf 'install-packages.sh: %s already queued for enrollment on next boot; skipping.\n' "${cert}"
          continue
        fi
        to_import+=("${cert}")
      done
      if [[ ${#to_import[@]} -gt 0 ]]; then
        "${SUDO[@]}" mokutil --import "${to_import[@]}"
      else
        printf 'install-packages.sh: all akmods MOK certs already enrolled or queued.\n'
      fi
    fi
  fi
}

user-groups() {
  "${SUDO[@]}" usermod -aG docker,keyd,libvirt,vboxusers "$USER"

  # Group changes only take effect on next login. Notify when the current
  # shell is missing either group — silent on re-runs after re-login.
  if ! id -nG | grep -qw docker || ! id -nG | grep -qw keyd || ! id -nG | grep -qw libvirt || ! id -nG | grep -qw vboxusers; then
    printf '\n'
    printf 'NOTE: Added "%s" to groups: docker, keyd, libvirt, vboxusers\n' "$USER"
    printf '      Log out and back in (or reboot) for group membership to take effect.\n'
  fi
}

fedora
dotnet-tools
akmods
virtualbox-extension-pack
systemd
user-groups
