#!/bin/bash

set -e -o pipefail

# Enable services
systemctl enable firewalld \
  && echo "Firewall service enabled."
systemctl enable keyd \
  && echo "Keyd service enabled."

# Set keymap
localectl set-x11-keymap kr \
  && echo "Keymap set to Korean."

# Initialize swap
btrfs subvolume create /swap \
  && btrfs filesystem mkswapfile --size 64g --uuid clear /swap/swapfile \
  && echo "/swap/swapfile none swap defaults 0 0" | tee -a /etc/fstab \
  && echo "Swapfile created and fstab updated."

# Set SDDM configuration
mkdir -p /etc/sddm.conf.d/ \
  && echo "[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
" | tee /etc/sddm.conf.d/10-wayland.conf \
  && echo "SDDM configured for Wayland."

sbctl create-keys \
  && sbctl enroll-keys -m -f \
  && sbctl verify | sed -E 's|^.* (/.+) is not signed$|sbctl sign -s "\1"|e' \
  && echo "All boot files are signed. Reboot to apply Secure Boot."
