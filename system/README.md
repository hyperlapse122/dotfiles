# system/

Root-owned config that ships to absolute system paths (`/etc/...`).

chezmoi manages files under `$HOME` and has no root-aware mode, so these files
are **not** chezmoi-managed targets. The whole `system/` tree is listed in the
repo-root [`.chezmoiignore`](../.chezmoiignore) so it is never linked into
`$HOME`. Instead it is installed to `/etc/` by a `run_onchange_after_` script:

[`.chezmoiscripts/linux/run_onchange_after_install-system-10-files.sh.tmpl`](../.chezmoiscripts/linux/run_onchange_after_install-system-10-files.sh.tmpl)

which runs:

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
of truth, like `packages.yaml` for packages. The installer script is a generic
engine that renders the manifest into bash arrays; **edit the data, not the
script**:

- Adding a file in a non-gated path requires no edit at all (files are
  discovered recursively at runtime; default mode `0644`).
- A non-default mode or a host gate is an `overrides:` entry (`path` is a bash
  glob matched against the path relative to `system/linux/`, first match wins).
- Deleting a tracked file requires adding its absolute `/etc` path to
  `removed:` in the same commit, so every machine — including ones that pull a
  committed deletion — removes the orphan on its next run. An optional
  `distro:` key scopes the removal to one distro (never deletes a native/user
  file elsewhere).

Gates are *named runtime probes* implemented by the engine (`thinkpad`, `vm`,
`ubuntu-studio`, `sddm-breeze`); an unknown gate name in the manifest aborts
the run, so typos fail loud. `check: visudo` validates a sudoers drop-in's
syntax on **every** host, even where the gate skips the install, so a broken
drop-in is caught on machines that never deploy it.

## How re-runs are triggered

The installer is a `run_onchange_` script: chezmoi only re-runs it when its
*rendered* contents change. The script embeds a `sha256` fingerprint of every
file under `system/linux/etc/` (via the shared
[`.chezmoitemplates/fingerprint.tmpl`](../.chezmoitemplates/fingerprint.tmpl)
partial), and the manifest is rendered inline — so adding, removing, or
editing any tracked file *or* any manifest entry forces the next
`chezmoi apply` to re-run the installer. Re-running is idempotent.

Force a re-run without changing any file with `chezmoi apply --force`.

## Layout

The path under `system/<os>/` mirrors the absolute install path exactly:

```
system/linux/etc/locale.conf
            └── installs to /etc/locale.conf
```

| Path | Used for |
|---|---|
| `etc/bluetooth/main.conf` | BlueZ daemon config: `Experimental`/`KernelExperimental = false`, `ControllerMode = dual` (Classic A2DP for stereo on Samsung Galaxy Buds, which only do mono over LE Audio on current BlueZ) |
| `etc/keyd/default.conf` | keyd keyboard remapping (CapsLock → Hangeul, meta layer) |
| `etc/libinput/local-overrides.quirks` | mark the keyd virtual keyboard as an internal keyboard |
| `etc/locale.conf` | system locale (`ko_KR.UTF-8`) |
| `etc/modprobe.d/` | kernel module options: Bluetooth USB autosuspend disable, plus ThinkPad-only `thinkpad_acpi fan_control=1` |
| `etc/modules-load.d/` | modules loaded at boot, currently ThinkPad-only `thinkpad_acpi` |
| `etc/sddm.conf.d/90-breeze.conf` | pin the SDDM login greeter to the stock Breeze theme (the `90-` prefix outranks vendor drop-ins); `sddm-breeze` gate skips it when the theme is not installed |
| `etc/security/limits.d/95-ubuntustudio-audio.conf` | `@audio` group realtime privileges (rtprio/memlock) — `ubuntu-studio` gate |
| `etc/sudoers.d/` | password-less sudo drop-ins (mode `0440`, `vm` gate, `visudo`-checked) |
| `etc/sysctl.d/` | sysctl drop-ins: TCP MTU probing, inotify watch limits, ptrace scope, and IPv4/IPv6 forwarding for the Tailscale exit-node path |
| `etc/udev/rules.d/` | udev rules: NuPhy Gem80 VIA/WebHID access, Logitech receiver wake disable, DualSense touchpad libinput ignore, Sennheiser BTD 600/700 dongle hidraw access |

## The install-system script set (10-files → 20-host → 30-network)

File installation is part 1 of a three-script set under
`.chezmoiscripts/linux/`, split by concern so each carries its own
`run_onchange_` trigger and re-run scope stays tight — editing a udev rule
re-runs the file installer only, without restarting network services the way
the old monolithic `install-system-config` script did:

| Script | Does | Re-runs when |
|---|---|---|
| `run_onchange_after_install-system-10-files.sh.tmpl` | install `system/linux/etc/**` per the manifest, remove orphaned `/etc` paths, ThinkPad modprobe, Ubuntu `locale-gen`, reload systemd/udev/sysctl for what it installed | any tracked file or manifest entry changes |
| `run_onchange_after_install-system-20-host.sh.tmpl` | user lingering, rootful podman socket mask, zram-swap disable (Fedora `systemd-zram-setup@` + Ubuntu `zramswap.service`, separate distro-guarded blocks) | its own content changes |
| `run_onchange_after_install-system-30-network.sh.tmpl` | firewalld (masquerade, `tailscale0` → trusted zone, WireGuard/STUN ports), `/etc/resolv.conf` → systemd-resolved, systemd-resolved/NetworkManager/tailscaled restarts, NetworkManager conf.d hygiene + reload | its own content changes |

The `10-`/`20-`/`30-` filename prefixes order execution (chezmoi runs scripts
alphabetically), so files land before anything that might depend on them.

All three scripts skip (`exit 0`) on headless/server installs — default boot
target not `graphical.target` and no display-manager enabled — and when sudo
credentials can't be obtained non-interactively, via the shared
`.chezmoitemplates/headless-guard.sh.tmpl` and `sudo-skip-guard.sh.tmpl`
partials. Override the headless skip with `INSTALL_SYSTEM_CONFIG_FORCE=1`;
note chezmoi records a clean skip as a successful run, so re-run by hand with
`chezmoi apply --force` on an interactive terminal.

There is no `system/macos/` or `system/windows/` tree. macOS settings usually
belong under `home/`/`Library/` (user-owned `~/Library` paths); Windows system
config does not fit the "drop a file at an absolute path" model.
