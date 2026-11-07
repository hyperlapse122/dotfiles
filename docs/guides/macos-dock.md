# macOS Dock

Explicit chezmoi application manages the Dock on native Apple Silicon macOS 26 or later.
Worktree preparation (`mise install`) and `chezmoi diff` do not change it.

## Preferences and Pins

Edit `home/.chezmoidata/macos-dock.json` to change the icon size, suggested/recent-app setting, or ordered app lists.
The group order is common, personal, work, then development/AI.
Within a group, each array represents one app; multiple bundle names are ordered alternatives for that same pin, as with T3 Code.
Finder remains the system-owned first icon, so it is not declared as a managed app entry.
Downloads is the only managed folder, followed by the system-owned Trash.

The initial declaration sets size 32 and disables suggested and recent apps.
Running apps can still appear normally.
1Password and OneNote are not pinned.
The JSON declaration is the authoritative list and order.

Application finds app bundles in `/Applications`, `~/Applications`, and `/System/Applications`.
For each candidate bundle name it checks those roots in that order.
It skips absent apps and includes them on a later application after they are installed.
It does not install Microsoft 365 apps or configure account sign-in or iCloud synchronization.

## Apply

From the selected worktree, explicitly apply personal configuration:

```sh
mise run apply
```

This is the repository's full apply, including its existing app, plugin, and build provisioning steps.
Follow the [macOS setup guide](../setup/macos.md#preview-and-apply), including closing active managed harness sessions first.

Every application restores the declared pin order and removes other manually added pins and folders.
Other Dock preferences, such as position, magnification, and automatic hiding, remain unchanged.
Retained app and Downloads entries keep their existing tile metadata, including folder display options.
If any managed preference changes, application briefly restarts the applying user's Dock once.
An unchanged application does not write preferences or restart Dock.

The after hook runs after app installation and uses the current worktree's mise-managed Python.
It writes only `tilesize`, `show-recents`, `persistent-apps`, and `persistent-others` through native `defaults`; it does not replace the entire preference domain or directly edit the live backing plist.
Write failures fail application.

## Verification

Run the focused checks without applying personal settings:

```sh
mise exec -- python -m unittest discover -s tests -p test_macos_dock.py -v
```

On macOS, the tests exercise actual `defaults` reads and writes against a temporary absolute plist domain.
The chezmoi lifecycle fixture executes the real rendered hook with fixture preferences and a recorded restart callback.
Neither fixture targets the account's live `com.apple.dock` or restarts its Dock.
The platform CI area includes these tests; native-defaults coverage is skipped on other operating systems.
These checks establish serialization and reconciliation behavior, not visual confirmation of a live desktop.
