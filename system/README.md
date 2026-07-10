# system/

Root-owned config that ships to absolute system paths (`/etc/...`).

chezmoi manages files under `$HOME` and has no root-aware mode, so these files
are **not** chezmoi-managed targets. The whole `system/` tree is listed in the
repo-root [`.chezmoiignore`](../.chezmoiignore) so it is never linked into
`$HOME`. Instead it is installed to `/etc/` by a `run_onchange_after_` script:

[`.chezmoiscripts/linux/run_onchange_after_install-system-config.sh.tmpl`](../.chezmoiscripts/linux/run_onchange_after_install-system-config.sh.tmpl)

which, on every `chezmoi apply`, runs:

```sh
sudo install -D -m <mode> "$SRC_ROOT"/etc/<abs/path> /etc/<abs/path>
```

`install -D` is the only correct tool here — it sets the mode atomically and
creates parent directories. `SRC_ROOT` points at this directory via chezmoi's
`.chezmoi.sourceDir` template variable, so files are read straight from the
source tree at apply time.

## How re-runs are triggered

The installer is a `run_onchange_` script: chezmoi only re-runs it when its
*rendered* contents change. The script embeds a `sha256` fingerprint of every
file under `system/linux/etc/` (generated at render time with `glob` +
`include` + `sha256sum`), so adding, removing, or editing any file here forces
the next `chezmoi apply` to re-run the installer. Re-running is idempotent.

Force a re-run without changing any file with `chezmoi apply --force`.

## Layout

The path under `system/<os>/` mirrors the absolute install path exactly:

```
system/linux/etc/locale.conf
            └── installs to /etc/locale.conf
```

Linux files are discovered recursively under `system/linux/etc/` and installed
with mode `0644` by default. Adding a file in a non-gated path does not require
editing the installer unless it needs a different mode or a host gate.

| Path | Used for |
|---|---|
| `etc/bluetooth/main.conf` | BlueZ daemon config: `Experimental`/`KernelExperimental = false`, `ControllerMode = dual` (Classic A2DP for stereo on Samsung Galaxy Buds, which only do mono over LE Audio on current BlueZ) |
| `etc/keyd/default.conf` | keyd keyboard remapping (CapsLock → Hangeul, meta layer) |
| `etc/libinput/local-overrides.quirks` | mark the keyd virtual keyboard as an internal keyboard |
| `etc/locale.conf` | system locale (`ko_KR.UTF-8`) |
| `etc/modprobe.d/` | kernel module options: Bluetooth USB autosuspend disable, plus ThinkPad-only `thinkpad_acpi fan_control=1` |
| `etc/modules-load.d/` | modules loaded at boot, currently ThinkPad-only `thinkpad_acpi` |
| `etc/sudoers.d/` | password-less sudo drop-ins (mode `0440`, VM-only via `systemd-detect-virt --vm`, `visudo`-checked) |
| `etc/sysctl.d/` | sysctl drop-ins: TCP MTU probing, inotify watch limits, ptrace scope, and IPv4/IPv6 forwarding for the Tailscale exit-node path |
| `etc/udev/rules.d/` | udev rules: NuPhy Gem80 VIA/WebHID access, Logitech receiver wake disable, DualSense touchpad libinput ignore |

## Gated paths (installer special-cases)

Two paths are not installed unconditionally:

- **`etc/sudoers.d/*`** — installed at mode `0440` (sudo refuses
  group/world-readable drop-ins) and only on virtual machines
  (`systemd-detect-virt --vm`). Syntax is checked with `visudo -c -f` on every
  host, so a broken drop-in is caught even where it will not be installed.
- **`etc/modprobe.d/thinkpad_acpi.conf`** and
  **`etc/modules-load.d/thinkpad_acpi.conf`** — installed only when
  `dmidecode -t system` reports a ThinkPad.

## Beyond file installation

After installing files, the script also performs host-level setup, each step
guarded so a missing prerequisite is skipped cleanly: removes orphaned `/etc`
paths listed in `REMOVED_ETC_PATHS`, reloads systemd/udev/sysctl, enables user
lingering, masks the rootful podman socket, disables zram swap, configures
firewalld (IPv4 masquerade, `tailscale0` → trusted zone, WireGuard/STUN ports),
points `/etc/resolv.conf` at systemd-resolved, and restarts
systemd-resolved/NetworkManager/tailscaled. See the script header for the full
rationale.

There is no `system/macos/` or `system/windows/` tree. macOS settings usually
belong under `home/`/`Library/` (user-owned `~/Library` paths); Windows system
config does not fit the "drop a file at an absolute path" model.
