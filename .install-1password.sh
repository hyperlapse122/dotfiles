#!/bin/sh

# exit immediately if both 1password and op is already in $PATH
command -v 1password >/dev/null 2>&1 \
  && command -v op >/dev/null 2>&1 \
  && op user get --me >/dev/null 2>&1 \
  && exit

### Install 1Password and 1Password CLI ###

# TODO: Switch script between macOS and Fedora Linux
# TODO: Skip installing when it's already installed

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

# TODO: Make user authenticate 1password and enable CLI access and wait for `op user get --me` succeeds
