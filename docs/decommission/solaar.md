# Solaar decommission checklist (operator-run, not automated)

> **Label:** Solaar decommission checklist. This document provides manual
> operator guidance for hosts that previously used Solaar or Logi Options+.
> Chezmoi executes none of it: the removal is source-only plus a `.chezmoiremove`
> prune, apply never removes packages or stops unmanaged GUI apps, and no
> teardown script exists or may be added.

**Perform application shutdown before or immediately after apply.**
OpenLogi and Solaar (or Logi Options+ on macOS) communicate directly with
Logitech hardware using the HID++ protocol. Running both managers at the same
time causes device access conflicts. Stop Solaar or Logi Options+ to ensure
OpenLogi gains exclusive control of the receiver.

Work through this checklist on each provisioned host.

## 1. Pre-apply: stop legacy services and quit applications

Stop running Solaar or Logi Options+ processes before applying the updated
dotfiles.

### Fedora (Linux)

- Stop and disable the Solaar user autostart service:
  ```sh
  systemctl --user stop app-solaar@autostart.service 2>/dev/null || true
  systemctl --user disable app-solaar@autostart.service 2>/dev/null || true
  rm -f ~/.config/autostart/solaar.desktop
  ```
- Terminate any running Solaar GUI processes:
  ```sh
  pkill -f solaar || true
  ```

### macOS

- Quit Logi Options+ from the menu bar icon, or terminate the process:
  ```sh
  pkill -f "Logi Options+" || true
  ```

## 2. Apply the updated source

Run your normal chezmoi apply:

```sh
chezmoi apply
```

The apply performs the following automated changes:
- Prunes the deployed `~/.config/solaar/rules.yaml` via `.chezmoiremove`.
- Removes `/etc/udev/rules.d/70-uinput-solaar.rules` via `.chezmoidata/system.yaml`.
- Asserts declared OpenLogi settings into `~/.config/openlogi/config.toml`.
- Enables and starts `openlogi-agent.service` on Linux.

**Verify the rules prune:**
```sh
ls ~/.config/solaar/rules.yaml 2>/dev/null || echo "Pruned successfully"
```
The command should output `Pruned successfully`.

## 3. Remove packages

Package removal is a manual step. This repository does not run package
uninstallation scripts.

### Fedora (Linux)

Remove Solaar and its udev package:
```sh
sudo dnf remove solaar solaar-udev
```

### macOS

Uninstall the Logi Options+ cask and zap residual files:
```sh
brew uninstall --zap logi-options-plus
```

## 4. Clean up the GNOME Shell extension (Fedora GNOME)

If the host runs GNOME Shell, remove the legacy Solaar battery extension.

- Disable and uninstall the extension through `gnome-extensions`:
  ```sh
  gnome-extensions disable solaar-extension@sidevesh 2>/dev/null || true
  gnome-extensions uninstall solaar-extension@sidevesh 2>/dev/null || true
  ```
- Remove `solaar-extension@sidevesh` from the GNOME Shell enabled-extensions setting:
  ```sh
  current="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo '[]')"
  python3 -c "
  import ast, sys
  val = sys.argv[1].removeprefix('@as ')
  try:
      exts = ast.literal_eval(val) if val else []
  except Exception:
      exts = []
  if 'solaar-extension@sidevesh' in exts:
      exts = [e for e in exts if e != 'solaar-extension@sidevesh']
      print(repr(exts))
  else:
      print('ABSENT')
  " "$current" | {
    read -r res
    if [ "$res" != "ABSENT" ] && [ -n "$res" ]; then
      gsettings set org.gnome.shell enabled-extensions "$res"
    fi
  }
  ```
- Remove any leftover extension files from disk:
  ```sh
  rm -rf ~/.local/share/gnome-shell/extensions/solaar-extension@sidevesh*
  ```

## 5. Remove leftover Solaar configuration

Solaar writes unmanaged device cache files to `~/.config/solaar/config.yaml`.
Chezmoi only prunes `rules.yaml`. Delete the remaining directory:

```sh
rm -rf ~/.config/solaar
```

## 6. Post-deploy verification

Verify that OpenLogi and mxm4-haptic operate correctly.

### Check OpenLogi device discovery and battery status

Run the OpenLogi CLI:
```sh
openlogi list
```
**Expected outcome:** OpenLogi lists paired devices, firmware versions, and
battery levels.

### Check OpenLogi service status (Linux)

Check the systemd user service:
```sh
systemctl --user status openlogi-agent.service
```
**Expected outcome:** The service status is `active (running)`.

### Verify mxm4-haptic coexistence (AE3)

Verify that the haptic stack functions alongside OpenLogi:
1. Ensure `openlogi-agent` and `mxm4-hapticd` are both running.
2. Send a desktop notification or trigger an OMP event:
   ```sh
   notify-send "OpenLogi Migration" "Haptic coexistence check"
   ```
3. **Expected outcome:** The MX Master 4 mouse plays a physical haptic pulse.
   The daemon log shows successful device communication without HID++ discovery
   retries or collisions.

## 7. Credential boundary — no credentials exist

Solaar and Logi Options+ do not use authentication credentials. There are no
passwords, API tokens, or 1Password items to rotate or delete.
