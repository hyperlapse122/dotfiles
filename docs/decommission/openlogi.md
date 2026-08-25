# OpenLogi Decommissioning Guide

Manual cleanup instructions for hosts that previously ran OpenLogi.

## Linux (Fedora)

1. Stop and disable the user service:
   ```sh
   systemctl --user stop openlogi-agent.service
   systemctl --user disable openlogi-agent.service
   ```

2. Remove the RPM package:
   ```sh
   sudo dnf remove openlogi
   ```

3. Remove user configuration and caches:
   ```sh
   rm -rf ~/.config/openlogi
   ```

## macOS

1. Quit the application if running.

2. Uninstall the Homebrew cask:
   ```sh
   brew uninstall --zap openlogi
   ```

3. Clean up any remaining configuration directories:
   ```sh
   rm -rf ~/.config/openlogi
   ```

## Verification

Confirm mxm4-haptic continues to function standalone:
```sh
mxm4-haptic "SingleLongSoftPulse"
```
