---
title: A NixOS override of a user unit that comes from the system path shadows the unit or replaces its PATH
date: "2026-10-20"
category: integration-issues
module: NixOS systemd user unit overrides (kde-baloo.service)
problem_type: integration_issue
component: systemd
severity: high
symptoms:
  - "baloo_file_extractor aborts thousands of times a boot: `Failed to create wl_display (No such file or directory)`, `could not connect to display`, `This application failed to start because no Qt platform plugin could be initialized`"
  - "The first attempt at a fix, `systemd.user.services.kde-baloo.environment`, wrote a complete /etc/systemd/user/kde-baloo.service with no ExecStart, which hides the packaged unit"
  - "With `overrideStrategy = \"asDropin\"` added, the generated overrides.conf also carried Environment=PATH, LOCALE_ARCHIVE, and TZDIR lines nobody asked for"
root_cause: wrong_api
resolution_type: config_change
tags: ["systemd", "user-unit", "drop-in", "overridestrategy", "asdropin", "kde", "plasma", "baloo", "qt-qpa-platform", "wayland", "kwin", "mutation-testing"]
---

# A NixOS override of a user unit that comes from the system path shadows the unit or replaces its PATH

## Problem

After the Plasma 6.7.5 to 6.8.0 update, Baloo's extractor crashed at startup in a loop. The fix needed one environment variable on `kde-baloo.service`, a user unit that KDE ships. The two obvious ways to set it from NixOS both break the unit, in different ways.

## Symptoms

- The journal shows the extractor failing to start and dumping core, over 2000 times per boot, with `baloo_file[...]: Extractor crashed` after each try.
- `coredumpctl` shows `.baloo_file_extractor-wrapped` aborting in `QGuiApplicationPrivate::createPlatformIntegration`.
- Earlier boots, still on Plasma 6.7.5, logged no crashes. The baloo store path stayed at the same version across the update; only its dependencies were rebuilt.

## What Didn't Work

- **Comparing the two baloo builds.** The old and new `baloo-6.30.0` outputs differ only in rebuilt dependencies. The extractor wrapper sets the same variables. The crash is not in baloo.
- **`systemd.user.services.kde-baloo.environment.QT_QPA_PLATFORM = "offscreen"`.** `kde-baloo.service` reaches the user manager through the system path, `/run/current-system/sw/share/systemd/user`, not through `systemd.packages`. The default `overrideStrategy`, `asDropinIfExists`, writes an override as a drop-in only when the unit tree NixOS builds from `systemd.packages` already holds a unit of that name, and otherwise as a complete unit file (nixpkgs `nixos/lib/systemd-unit-options.nix`, the `overrideStrategy` option, and `nixos/lib/systemd-lib.nix`, the `asDropinIfExists` filter in the unit-tree builder). It writes `/etc/systemd/user/kde-baloo.service` with only `[Service] Environment=...`. `/etc/systemd/user` precedes the system path, so that bare file replaces the packaged unit and its `ExecStart`.
- **The same option with `overrideStrategy = "asDropin"`.** That produced `kde-baloo.service.d/overrides.conf`, but the drop-in built in this session also set `Environment="PATH=<coreutils, findutils, grep, sed, systemd>"`, `LOCALE_ARCHIVE`, and `TZDIR`. The `PATH` comes from the service's default `path` list (nixpkgs `nixos/lib/systemd-lib.nix`, `environment.PATH = mkIf (config.path != [ ]) ...`). A drop-in that sets `PATH` replaces the session's `PATH` for `baloo_file` and everything it spawns, which the fix never meant to change.

## Solution

Write the drop-in as a raw unit, as a drop-in explicitly, in `modules/nixos/desktop/desktop.nix`:

```nix
systemd.user.units."kde-baloo.service" = {
  overrideStrategy = "asDropin";
  text = ''
    [Service]
    Environment=QT_QPA_PLATFORM=offscreen
  '';
};
```

The built `/etc/systemd/user` tree then holds only `kde-baloo.service.d/overrides.conf` with that one line, and the packaged unit stays the fragment.

`tests/baloo-extractor.nix` guards it. It reads the built generation rather than the option and resolves the unit the way the user manager does:

- Unit directories in priority order: Home Manager's `~/.config/systemd/user`, `/etc/systemd/user` (through `tests/lib/etc-file.nix`), and `share/systemd/user` under the system path.
- `Environment=` read only from `[Service]` sections.
- Drop-ins merged across those directories in name order, with a higher directory hiding a drop-in of the same name below it.

The check then runs the real extractor with that environment and no display. It also runs a real indexing pass: `baloo_file` on a private `dbus-run-session` bus, with a `baloofilerc` fixture, until `baloosearch6` finds a word from a fixture file's content.

## Why This Works

The crash chain:

1. `kde-baloo.service` is `PartOf=` and `WantedBy=` `graphical-session.target`, and `plasma-workspace.target` pulls it in with `Wants=kde-baloo.service`. Nothing orders it after KWin. In this session it started at 08:56:49.698, and `kwin_wayland` started at 08:56:49.776. `baloo_file` therefore inherits a manager environment without `WAYLAND_DISPLAY` or `DISPLAY`, and every extractor it spawns inherits the same environment.
2. The extractor's `main()` constructs a `QGuiApplication` (baloo `src/file/extractor/main.cpp`). With `WAYLAND_DISPLAY` unset, libwayland connects to `wayland-0`.
3. Under KWin 6.7.5 this worked by accident: per this session's journals, no boot on 6.7.5 logged an extractor crash, consistent with that KWin creating `wayland-0`. KWin 6.8.0's wrapper starts numbering at `wayland-1` (kwin `src/helpers/wayland_wrapper/wl-socket.c`, `int displayno = 1;`). Wayland fails with ENOENT, xcb fails with an empty `DISPLAY`, and Qt calls `qFatal`.

`offscreen` needs no display, and the extractor draws nothing. `baloo_file` itself is a `QCoreApplication`, so the variable does not change it.

## Prevention

- To change a unit that a package provides through the system path rather than `systemd.packages`, which covers most KDE user units, set `overrideStrategy = "asDropin"`. Check the built `/etc/systemd/user` tree for a bare `<unit>.service`. Its presence means the override replaced the unit.
- Use `systemd.user.units."<name>".text` for an environment-only drop-in. `systemd.user.services.<name>.environment` also emits the default `PATH`, `LOCALE_ARCHIVE`, and `TZDIR`.
- A check that stands in for a unit's environment must model systemd's merge: `[Service]`-only keys, every unit directory including Home Manager's, same-name precedence, and name order. Each simpler reading had a green-while-red mutation in this session. These were an `Environment=` placed under `[Unit]`, a disabled `/etc/systemd/user` entry, and a later-sorting `zz.conf` in the system path or in Home Manager. Mutating the fix to each override form above also turns the check red.
- A Qt service that starts before KWin exports its display variables now fails rather than finding `wayland-0` by luck. Suspect this first for any `QGuiApplication` user service that started aborting with Plasma 6.8.

## Related

- [plasma-apply-colorscheme no-op under the kdeglobals cascade](plasma-apply-colorscheme-no-op-under-xdg-kdeglobals-cascade.md): another KDE tool that aborts in `QGuiApplication` without a display, worked around there with `QT_QPA_PLATFORM=offscreen` too.
- [Unit existence tests that pass for a unit masked to /dev/null](../best-practices/nix-check-unit-existence-passes-for-masked-unit.md): a sibling case where the materialized unit tree looks fine while the packaged unit no longer runs.
- [Checks that read an option value instead of the materialized output](../best-practices/nix-check-reads-option-value-not-materialized-output.md): why the check resolves the built unit directories rather than the option.
