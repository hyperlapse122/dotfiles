# system/

Root-owned config that ships to absolute system paths (`/etc/...`).

chezmoi manages files under `$HOME` and has no root-aware mode, so these files
are **not** chezmoi-managed targets. The whole `system/` tree is listed in the
repo-root [`.chezmoiignore`](../.chezmoiignore) so it is never linked into
`$HOME`. Instead it is installed to `/etc/` by modular
`run_onchange_after_install-system-*.sh.tmpl` scripts under `.chezmoiscripts/30-linux/`:

which run:

```sh
sudo install -D -m <mode> "$SRC_ROOT"/etc/<abs/path> /etc/<abs/path>
```

`install -D` is the only correct tool here — it sets the mode atomically and
creates parent directories. `SRC_ROOT` points at this directory via chezmoi's
`.chezmoi.sourceDir` template variable, so files are read straight from the
source tree at apply time.

## The manifest: `.chezmoidata/system.yaml`

Per-path install **modes**, host **gates**, source **checks**, and the
**removed-path** cleanup list all live in
[`.chezmoidata/system.yaml`](../.chezmoidata/system.yaml) — the single source
of truth, organized by subsystem:
- Adding a file in a non-gated path requires no edit at all (files are
  discovered recursively at runtime; default mode `0644`).
- A non-default mode or a host gate is an `overrides:` entry (`path` is a bash
  glob matched against the path relative to `system/linux/`, first match wins).
- Deleting a tracked file requires adding its absolute `/etc` path to
  `removed:` in the same commit, so every machine — including ones that pull a
  committed deletion — removes the orphan on its next run. An optional
  `distro:` key scopes the removal to one distro (never deletes a native/user
  file elsewhere).

Gates are *named host facts* from the registry (`.chezmoidata/facts.yaml`) —
`thinkpad`, `ux534`, `vm`, `sddmBreeze`, `gdm`, `fprintdPam`. The
installer no longer probes for any of them: `gate_ok()` is a lookup into the
`FACT_*` variables the registry resolved once for this chezmoi command. A gate
naming a fact the registry does not declare aborts the render, so typos fail
loud before anything is touched. See the *Host facts* section of `AGENTS.md`
for the registry model and how to add one.

`check: visudo` validates a sudoers drop-in's syntax on **every** host, even
where the gate skips the install, so a broken drop-in is caught on machines that
never deploy it. It is a file validator, not a fact — which is why it stays a
runtime case in the installer.

## How re-runs are triggered

The installers are `run_onchange_` scripts: chezmoi only re-runs a subsystem
script when its *rendered* contents or fingerprinted files change. Each script
embeds a `sha256` fingerprint of its managed files under `system/linux/etc/`
(via `.chezmoitemplates/fingerprint.tmpl`), so modifying a file in one
subsystem only re-runs that specific subsystem installer.

Force a re-run without changing any file with `chezmoi apply --force`.

## Layout

The path under `system/<os>/` mirrors the absolute install path exactly:

```
system/linux/etc/locale.conf
            └── installs to /etc/locale.conf
```

| Path | Used for |
|---|---|
| `etc/dracut.conf.d/resume.conf` | dracut initramfs resume module for hibernation |
| `etc/dracut.conf.d/bluetooth.conf` | dracut initramfs bluetooth module |
| `etc/bluetooth/main.conf` | BlueZ daemon config: `Experimental`/`KernelExperimental = true`, `ControllerMode = dual` (Classic A2DP dual mode so stereo audio stays available on TWS earbuds that fall back to mono over LE Audio on current BlueZ) |
| `etc/dconf/` | GDM greeter password-only (`gdm` gate): profile override adding `system-db:gdm` + `gdm.d` keyfile/lock disabling `enable-fingerprint-authentication`, so the login keyring always unlocks; the user-session lock screen keeps fingerprint. Compiled by the installer's `dconf update` |
| `etc/libinput/local-overrides.quirks` | mark the keyd virtual keyboard as an internal keyboard |
| `etc/locale.conf` | system locale (`ko_KR.UTF-8`) |
| `etc/modprobe.d/` | kernel module options: Bluetooth USB autosuspend disable, plus ThinkPad-only `thinkpad_acpi fan_control=1` |
| `etc/modules-load.d/` | modules loaded at boot, currently ThinkPad-only `thinkpad_acpi` |
| `etc/sddm.conf.d/90-breeze.conf` | pin the SDDM login greeter to the stock Breeze theme (the `90-` prefix outranks vendor drop-ins); `sddmBreeze` gate skips it when the theme is not installed |
| `etc/sudoers.d/` | password-less sudo drop-ins (mode `0440`, `vm` gate, `visudo`-checked) |
| `etc/sysctl.d/` | sysctl drop-ins: TCP MTU probing, inotify watch limits, ptrace scope, and IPv4/IPv6 forwarding for the Tailscale exit-node path |
| `etc/udev/rules.d/` | udev rules: NuPhy Gem80 VIA/WebHID access, Logitech receiver wake disable, DualSense touchpad libinput ignore, Sennheiser BTD 600/700 dongle hidraw access, UX534 battery charge ceiling (gated) |

## The modular install-system script set (30-linux)

System file installation is modularized across discrete `run_onchange_after_`
scripts under `.chezmoiscripts/30-linux/`, split by subsystem concern:

| Script | Does | Re-runs when |
|---|---|---|
| `run_onchange_after_install-system-10-desktop.sh.tmpl` | locale, SDDM theme drop-in, GDM dconf override + `dconf update` | desktop files or desktop manifest section change |
| `run_onchange_after_install-system-12-sudoers.sh.tmpl` | password-less sudoers drop-in (mode `0440`, `visudo` check) | `etc/sudoers.d/*` files change |
| `run_onchange_after_install-system-14-sysctl.sh.tmpl` | sysctl drop-ins + `sysctl --system` reload | `etc/sysctl.d/*` files change |
| `run_onchange_after_install-system-16-udev.sh.tmpl` | udev rules, libinput quirks, removed rules + `udevadm control --reload` | `etc/udev/rules.d/*` or `libinput/*` files change |
| `run_onchange_after_install-system-18-hardware.sh.tmpl` | ThinkPad module config + `modprobe thinkpad_acpi`; on a UX534, the ScreenPad backlight-unit mask and this host's grubby kernel arguments | modprobe/modules-load files change, or the rendered UX534 block changes |
| `run_onchange_after_install-system-20-bluetooth.sh.tmpl` | BlueZ config, autosuspend + `systemctl restart bluetooth` | `etc/bluetooth/*` files change |
| `run_onchange_after_install-system-22-host.sh.tmpl` | user lingering, rootful podman socket mask | its own content changes |
| `run_onchange_after_install-system-24-keyd.sh.tmpl` | keyd hardware probe, package install, config generation | keyd keyboards data or quirks file change |
| `run_onchange_after_install-system-26-swap-hibernate.sh.tmpl` | zram disable, Btrfs @swap subvol, swapfile creation, grubby/dracut hibernation setup | `etc/dracut.conf.d/*` files or own content change |
| `run_onchange_after_install-system-30-network.sh.tmpl` | firewalld, resolv.conf → systemd-resolved, NM hygiene | its own content changes |
The `10-`/`20-`/`30-` filename prefixes order execution (chezmoi runs scripts
alphabetically), so files land before anything that might depend on them.

All these scripts skip (`exit 0`) on headless/server installs — default boot
target not `graphical.target` and no display-manager enabled — via the shared
`.chezmoitemplates/headless-guard.sh.tmpl` partial. Override that skip with
`INSTALL_SYSTEM_CONFIG_FORCE=1`; note chezmoi records a clean skip as a
successful run, so re-run by hand with `chezmoi apply --force`.

Elevation is different: `.chezmoitemplates/sudo-elevation-guard.sh.tmpl` walks
a ladder (already root, cached/NOPASSWD sudo, a TTY to prompt on, the desktop's
own askpass helper) and **fails with `exit 1`** when no rung succeeds, rather
than skipping. A host that cannot elevate is therefore never recorded as
provisioned: chezmoi does not record a failed run, so the next `chezmoi apply`
retries the script by itself. To supply an elevation path, give the run a
terminal (`ssh -t`) or authenticate first with `sudo -v`.

There is no `system/macos/` tree: macOS settings belong under user-owned
`Library/` (`~/Library`) paths.
