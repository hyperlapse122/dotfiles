#!/usr/bin/env bash
#
# chezmoi `read-source-state.pre` hook — installs the tooling chezmoi needs
# *before* it reads the source state:
#
#   * 1Password + 1Password CLI (`op`) — secret templates call `onepasswordRead`,
#     which requires an authenticated `op`.
#   * mise — the runtime / CLI version manager the rest of this config relies on.
#
# chezmoi runs a hook `command` verbatim and never renders it as a template, so
# this file MUST NOT be a `.tmpl`. OS divergence is therefore decided at runtime
# from `uname`, not from Go-template `{{ .chezmoi.os }}` branches.

set -euo pipefail

# Fast path: nothing to do once both tools are present and `op` is signed in.
# Keeps re-runs cheap — chezmoi invokes this hook on every `init`/`apply`.
if command -v op >/dev/null 2>&1 \
  && command -v mise >/dev/null 2>&1 \
  && op user get --me >/dev/null 2>&1; then
  exit 0
fi

# Fedora: install via dnf, mirroring .chezmoidata/packages.yaml (1Password's
# stable RPM repo + the jdxcode/mise COPR). Skips work that is already done so
# the hook is idempotent across re-runs.
install_fedora() {
  # Use sudo only when not already root (matches the package-install script).
  # Throw early if neither root nor sudo is available — dnf needs it.
  local -a SUDO
  if [[ "${EUID}" -eq 0 ]]; then
    SUDO=()
  elif command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  else
    printf 'install-prerequisites.sh: requires root or sudo for package installation.\n' >&2
    exit 1
  fi

  if ! rpm -q 1password 1password-cli >/dev/null 2>&1; then
    "${SUDO[@]}" tee /etc/yum.repos.d/1password.repo >/dev/null <<'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey="https://downloads.1password.com/linux/keys/1password.asc"
EOF
    "${SUDO[@]}" dnf install 1password 1password-cli -y
  fi

  if ! rpm -q gh zsh git-lfs >/dev/null 2>&1; then
    "${SUDO[@]}" dnf install gh zsh git-lfs -y
  fi

  if ! rpm -q mise >/dev/null 2>&1; then
    "${SUDO[@]}" dnf copr enable jdxcode/mise -y
    "${SUDO[@]}" dnf install mise -y
  fi
}

# macOS: install via Homebrew, bootstrapping Homebrew itself when it is missing
# (it is the package manager the macOS side of this config assumes — see the
# /opt/homebrew PATH wiring in dot_config/zsh/dot_zprofile).
install_macos() {
  if ! command -v brew >/dev/null 2>&1; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  # Make `brew` usable in this non-login shell for the installs below.
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  brew list --cask 1password >/dev/null 2>&1 || brew install --cask 1password
  brew list --cask 1password-cli >/dev/null 2>&1 || brew install --cask 1password-cli
  brew list mise >/dev/null 2>&1 || brew install mise
}

case "$(uname -s)" in
  Darwin) install_macos ;;
  Linux) install_fedora ;;
  *)
    printf 'install-prerequisites.sh: unsupported OS %s.\n' "$(uname -s)" >&2
    exit 1
    ;;
esac

# TODO: Make user authenticate 1password and enable CLI access and wait for `op user get --me` succeeds
