#!/usr/bin/env bash
# archinstall/post-install.sh
#
# Bootstraps this dotfiles repo on a fresh Arch system.
#
# Designed for two callers:
#   1. archinstall's `custom_commands` — runs as root inside arch-chroot of the
#      new system, after package install and before unmount.
#   2. Manual re-run on an already-installed Arch box.
#
# Usage:
#   sudo bash post-install.sh <username> [repo-url]
#   curl -fsSL <raw-url>/archinstall/post-install.sh | sudo bash -s -- <username>
#
# Args:
#   $1  target username (required, must NOT be root)
#   $2  dotfiles repo URL (optional)
#
# Platform-specific by design (see AGENTS.md "Script parity"): runs only on
# Arch Linux. There is no .ps1 counterpart.

set -euo pipefail

USERNAME="${1:-}"
REPO_URL="${2:-https://github.com/hyperlapse122/dotfiles.git}"

if [[ -z "$USERNAME" || "$USERNAME" == "root" ]]; then
  printf 'post-install.sh: usage: %s <username> [repo-url]\n' "$0" >&2
  printf 'post-install.sh: <username> must be non-root and exist in /etc/passwd.\n' >&2
  exit 64
fi

USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
if [[ -z "$USER_HOME" ]]; then
  printf 'post-install.sh: user %s not found in /etc/passwd\n' "$USERNAME" >&2
  exit 1
fi

# 1. Prereqs (idempotent — pacman --needed skips installed packages).
pacman -Sy --noconfirm --needed git curl

# 2. Install uv for the target user (drops into ~/.local/bin).
if [[ ! -x "$USER_HOME/.local/bin/uv" ]]; then
  sudo -u "$USERNAME" sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
fi

# 3. Clone or update the dotfiles repo into ~/dotfiles.
DOTFILES_DIR="$USER_HOME/dotfiles"
if [[ ! -d "$DOTFILES_DIR/.git" ]]; then
  sudo -u "$USERNAME" git clone "$REPO_URL" "$DOTFILES_DIR"
else
  sudo -u "$USERNAME" git -C "$DOTFILES_DIR" pull --ff-only
fi

# 4. Run install.sh as the target user. install.sh is idempotent.
sudo -u "$USERNAME" bash "$DOTFILES_DIR/install.sh"

printf 'post-install.sh: bootstrap complete for %s\n' "$USERNAME"
