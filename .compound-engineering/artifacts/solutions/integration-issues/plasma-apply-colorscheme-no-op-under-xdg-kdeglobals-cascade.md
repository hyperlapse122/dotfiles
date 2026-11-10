---
title: "plasma-apply-colorscheme silently no-ops when /etc/xdg/kdeglobals already names the scheme"
date: "2026-09-27"
category: integration-issues
module: "KDE Plasma color scheme (Home Manager activation, home/h82/desktop/kde/theme.nix)"
problem_type: integration_issue
component: activation
severity: medium
symptoms:
  - "plasma-apply-colorscheme aborts with SIGABRT in QGuiApplication when run from Home Manager activation with no display"
  - "With QT_QPA_PLATFORM=offscreen it exits 0 printing 'The requested theme \"BreezeDark\" is already set' and writes nothing, while ~/.config/kdeglobals keeps its light [Colors:*] groups"
  - "The no-op happens even without any per-user ColorScheme write, because the effective General/ColorScheme comes from the /etc/xdg/kdeglobals cascade shipped by modules/nixos/desktop/desktop.nix"
  - "A check reading only ~/.config/kdeglobals reports missing keys that are correctly dark by cascade, because KConfig removes a user entry equal to the system default"
root_cause: wrong_api
resolution_type: code_fix
related_components:
  - testing_framework
  - home-manager
tags: ["kde-plasma", "kdeglobals", "plasma-apply-colorscheme", "kwriteconfig6", "kconfig-cascade", "xdg-config-dirs", "home-manager", "breeze-dark"]
---

# plasma-apply-colorscheme silently no-ops when /etc/xdg/kdeglobals already names the scheme

## Problem

The KDE dark-theme change (branch `hyperlapse122/feat-kde-dark-theme`) makes Breeze Dark the default Plasma theme. It does this in two layers:

- **System layer.** `modules/nixos/desktop/desktop.nix` originally rendered `/etc/xdg/kdeglobals` with `[General] ColorScheme=BreezeDark`, `[Icons] Theme=breeze-dark`, and `[KDE] LookAndFeelPackage=org.kde.breezedark.desktop`, then appended the `[Colors:*]`, `[ColorEffects:*]`, and `[WM]` groups from the packaged `BreezeDark.colors`. Today it renders `ColorScheme=BreezeLight`, `Icons Theme=breeze`, `AutomaticLookAndFeel=true` with `DefaultLightLookAndFeel`/`DefaultDarkLookAndFeel`, and `LookAndFeelPackage=org.kde.breeze.desktop`, and appends the groups from `BreezeLight.colors`.
- **User layer.** A Home Manager activation, `home.activation.kdeTheme` in `home/h82/desktop/kde/theme.nix`, converts h82's existing user.

New users picked up the dark defaults, but h82 stayed light. h82's long-lived `~/.config/kdeglobals` had no `ColorScheme` key. It did carry its own light `[Colors:*]` groups, for example `[Colors:Window] BackgroundNormal=239,240,241`. KConfig lets user-file groups override `/etc/xdg`, so those light colors won over the system dark defaults.

The first user-layer design called `plasma-apply-colorscheme BreezeDark` (from `kdePackages.plasma-workspace`) from the activation. That design failed twice:

1. It aborted when there was no display.
2. Once it could run, it exited 0 and wrote nothing.

The second failure is the core trap. `plasma-apply-colorscheme` decides whether a scheme is "already set" from the **effective** `[General] ColorScheme`, and that value includes the KConfig XDG cascade. `/etc/xdg/kdeglobals` already said `BreezeDark`, so the tool printed:

```text
The requested theme "BreezeDark" is already set as the theme for the current Plasma session.
```

It then exited 0 without touching the user's light color groups.

## Symptoms

The tool behavior below was observed in this session against `plasma-workspace` and KConfig as pinned by this flake's `flake.lock`; recheck it after a Plasma upgrade.

- After a rebuild, h82's Qt/KDE apps stayed light while `/etc/xdg/kdeglobals` correctly held Breeze Dark.
- In a Home Manager activation with no display, `plasma-apply-colorscheme` died with SIGABRT inside `QGuiApplication`.
- With `QT_QPA_PLATFORM=offscreen` and the real system config visible, it exited 0 and printed "already set as the theme for the current Plasma session", and the user file was unchanged.
- In a sandbox with no `/etc/xdg` defaults, the same command printed `Successfully applied the color scheme BreezeDark`. The bug disappeared exactly when the cascade was absent.
- A grep over the activation script text passed throughout, because the command was present even though it did nothing.

## What Didn't Work

1. **`plasma-apply-colorscheme` without a display platform.** It aborts in `QGuiApplication` with SIGABRT, because activation has no display. `QT_QPA_PLATFORM=offscreen` gets past this, but that only exposed the next failure.
2. **`kwriteconfig6 --key ColorScheme BreezeDark` before `plasma-apply-colorscheme`.** Writing the scheme name first guarantees the "already set" short-circuit, so the apply step becomes a no-op. Document review caught this before it was run.
3. **Reordering so `plasma-apply-colorscheme` owns the `ColorScheme` write.** This was still a no-op in production, because the effective value comes from `/etc/xdg/kdeglobals` through the cascade, not from the user file. The smoke test passed only because it ran under `env -i` with no `XDG_CONFIG_DIRS`, so the tool never saw the system default. The bug was reproduced by running the activation's `data` with `XDG_CONFIG_DIRS=<built etc>/etc/xdg` against a copy of the real user `kdeglobals`. With that setup the tool printed "already set" and left the light groups in place.
4. **Checking that a key is present in the user file.** In the sandbox check, `LookAndFeelPackage` looked unwritten in the user file even though it resolved correctly. KConfig, including `kwriteconfig6`, does not store a user entry whose value equals the cascaded system default, and it removes one if it exists. "Key absent from the user file" therefore does not mean "write missing", and a presence check both flags false failures and invites the wrong fix.

## Solution

> **Historical:** `home/h82/desktop/kde/theme.nix` no longer has this design. It now sets `AutomaticLookAndFeel` with `DefaultLightLookAndFeel`/`DefaultDarkLookAndFeel`, and deletes the user's `ColorScheme`, `ColorSchemeHash`, and `Icons Theme` pins with `XDG_CONFIG_DIRS=/var/empty`, so Plasma applies the scheduled theme at login. `modules/nixos/desktop/desktop.nix` renders `/etc/xdg/kdeglobals` with `ColorScheme=BreezeLight`, and the check is `kde-theme` (`tests/kde-theme.nix`). The mechanics below describe the original implementation. The cascade lesson still applies: any tool or check that reads the effective config sees `/etc/xdg`, not just the user file.

Drop `plasma-apply-colorscheme` and write the scheme's color entries into the user file directly with `kwriteconfig6`. Build the entry list from the packaged scheme so it follows Breeze upgrades.

The original `home/h82/desktop/kde/theme.nix` generated the list at build time. It is one `group<TAB>key<TAB>value` line per entry in `[Colors:*]`, `[ColorEffects:*]`, and `[WM]`. Nested groups such as `[Colors:Header][Inactive]` are joined with `/`:

```nix
darkColors = pkgs.runCommand "breeze-dark-color-entries" { nativeBuildInputs = [ pkgs.gawk ]; } ''
  awk '
    /^\[/ {
      keep = ($0 ~ /^\[(Colors|ColorEffects):/ || $0 == "[WM]")
      group = substr($0, 2, length($0) - 2)
      gsub(/\]\[/, "/", group)
      next
    }
    keep && index($0, "=") > 1 {
      eq = index($0, "=")
      printf "%s\t%s\t%s\n", group, substr($0, 1, eq - 1), substr($0, eq + 1)
    }
  ' ${pkgs.kdePackages.breeze}/share/color-schemes/BreezeDark.colors > $out
'';
```

The original activation wrote the three identity keys and then loops over the list. For each nested level it passes a separate `--group`:

```nix
home.activation.kdeTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  if [ -x "${kwrite}" ]; then
    ${kwrite} --file kdeglobals --group General --key ColorScheme BreezeDark
    ${kwrite} --file kdeglobals --group KDE --key LookAndFeelPackage org.kde.breezedark.desktop
    ${kwrite} --file kdeglobals --group Icons --key Theme breeze-dark

    while IFS=$'\t' read -r group key value; do
      group_args=()
      IFS=/ read -ra groups <<< "$group"
      for g in "''${groups[@]}"; do
        group_args+=(--group "$g")
      done
      ${kwrite} --file kdeglobals "''${group_args[@]}" --key "$key" -- "$value"
    done < ${darkColors}
  fi
'';
```

`kwrite` is `${pkgs.kdePackages.kconfig}/bin/kwriteconfig6` (still the `kwrite` binding in `theme.nix`). The activation takes about 1.8 s. It needs no display and no `QT_QPA_PLATFORM`.

Regression check: `tests/kde-dark-theme.nix`, registered as `kde-dark-theme` in `flake.nix`. The default later moved to Breeze Light with the same two-layer mechanism, and then to automatic switching between Breeze and Breeze Dark, where Plasma's own login-time apply and `lookandfeelautoswitcher` write the colors and the activation no longer copies them; the check is now `tests/kde-theme.nix` (`kde-theme`).

## Why This Works

- `kwriteconfig6` writes the value it is given. It has no "already applied" short-circuit based on the effective `ColorScheme`, so the cascade cannot turn it into a no-op.
- Overwriting every `[Colors:*]`/`[ColorEffects:*]`/`[WM]` entry in the user file replaces the light groups that were overriding `/etc/xdg`. The user file now either resolves to the dark values directly, or KConfig drops the entry because it equals the dark system default and the lookup falls through to `/etc/xdg`. Either way the effective value is dark.
- Passing one `--group` per nesting level addresses `[Colors:Header][Inactive]` as a real subgroup. Joining the levels into one group name writes a different, unrelated group and leaves the light subgroup in place.
- Generating the list from `${pkgs.kdePackages.breeze}/share/color-schemes/BreezeDark.colors` keeps the user values identical to what `desktop.nix` appends to `/etc/xdg/kdeglobals` from the same file.

The activation runs only when the Home Manager generation changes, not on every rebuild (see the comment above `home.activation.kdeTheme` in `theme.nix`; see `.compound-engineering/artifacts/solutions/best-practices/home-manager-activation-does-not-run-on-every-rebuild.md`). It converts the user file once. Nothing reasserts dark on each switch.

## Prevention

- **Treat any "apply" tool that reads the effective config as a possible silent no-op when `/etc/xdg` sets the same value.** Before relying on `plasma-apply-colorscheme`, `plasma-apply-lookandfeel`, or similar tools in activation, run them with the real `XDG_CONFIG_DIRS` pointed at the built `/etc/xdg`. A test under `env -i`, or one with no `XDG_CONFIG_DIRS`, hides the cascade and gives the misleading "Successfully applied" result.
- **Run the real activation, not a grep of its text.** The retired `tests/kde-dark-theme.nix` took `home-manager.users.h82.home.activation.kdeTheme.data` and ran it with `bash` under a fixture `HOME`, with `XDG_CONFIG_DIRS` set to `${host.config.system.build.etc}/etc/xdg`. `tests/kde-theme.nix` keeps the same approach: it runs `kdeTheme.data` against fixture HOMEs with the session's `XDG_CONFIG_DIRS` (the `kdeEnv` binding).
- **Seed the fixture with the wrong values, not with missing keys.** The retired check's fixture user `kdeglobals` contained `ColorScheme=BreezeLight`, `Icons Theme=breeze`, `LookAndFeelPackage=org.kde.breeze.desktop`, and every `[Colors:*]` group from `BreezeLight.colors`. If keys are merely absent, the dark `/etc/xdg` defaults fill them in and a dropped write still passes. This is the converged-fixture trap in `.compound-engineering/artifacts/solutions/best-practices/converged-fixture-state-defeats-nix-check-mutation-testing.md`.
- **Assert the resolved value, not the presence of a user key.** `ini_effective` (in `tests/kde-theme.nix` too) returns the user file's value when the group and key exist there, and the `/etc/xdg` value otherwise. That matches KConfig's behavior of dropping user entries equal to the cascaded default; `ini_mentions` there also catches a `Key[$d]` deletion marker. Include at least one nested group in the assertions. The retired check compared both `[Colors:Window]` and `[Colors:Header][Inactive]` `BackgroundNormal` against values read from `BreezeDark.colors`, and confirmed the dark value differs from `BreezeLight.colors` so a light scheme cannot pass.
- **Mutation-test the check.** Each of these five mutations made the retired `kde-dark-theme` check fail:
  - dropping the `ColorScheme` write
  - dropping the `LookAndFeelPackage` write
  - dropping the `Icons/Theme` write
  - emptying the color entry list
  - joining nested group levels into one group name

  Repeat this after changing the activation or the fixture.
- **Keep hardware verification separate.** The check cannot observe whether a running Plasma session repaints; confirm that on hardware and report it separately from repository checks (see `CONCEPTS.md` and `AGENTS.md`).

## Related

- [kwriteconfig6 --delete writes a deletion marker that masks kdedefaults](kwriteconfig6-delete-writes-masking-marker-over-cascaded-default.md): the delete side of the same cascade, used by the current `theme.nix`.
