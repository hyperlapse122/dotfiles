# system/

Root-owned config that ships to absolute system paths (`/etc/...`, etc.).

These files are **NOT** managed by chezmoi — chezmoi only handles user-owned `$HOME` content. They are installed by `scripts/linux/install-linux-system-config.sh`, called directly from `install.sh`, using:

```sh
sudo install -D -m <mode> system/<os>/<abs/path> /<abs/path>
```

`install -D` is the only correct tool here — it sets mode atomically and creates parent directories. **Don't** use `sudo cp` (no atomic mode/owner) and **don't** try to express these as chezmoi-managed files (chezmoi runs as the user and cannot write to `/etc/`).

Linux system files are discovered recursively under `system/linux/etc/` and
installed with mode `0644` by default. Exceptions are `system/linux/etc/sudoers.d/*`
(mode `0440`, VM-only via `systemd-detect-virt --vm`, syntax-checked with
`visudo -c -f`) and the ThinkPad `thinkpad_acpi` module-load/modprobe drop-ins
(installed only when `dmidecode -t system` reports a ThinkPad). Adding files
outside those gated paths should not require editing the installer unless they
need a different mode or a platform/host gate.

After file install, the installer runs `systemctl daemon-reload`
when `system/linux/etc/systemd/system/` exists, then calls
`loginctl enable-linger "${SUDO_USER:-$USER}"` so the user-scope
`home/.config/systemd/user/podman-prune.{service,timer}` pair
(plus the rootless `podman.socket` from the podman package) can
keep running without an active login session. It then
`systemctl mask`s the rootful `podman.socket` and
`podman.service` to block the system-level rootful podman API
(sudo `podman` itself is daemonless and unaffected, and the
user-scope prune timer is enabled separately by `install.linux.yaml`
alongside the rootless `podman.socket`, soft-skipped when no user
session bus is reachable, same as the `mxm4-haptic*` units). The
podman-prune pair is **Linux-only**, so the user unit has no
`.ps1` counterpart (script-parity exception: podman is Linux-only
in this dotfiles setup). It then enables firewalld IPv4 masquerading
on the default zone (`firewall-cmd --permanent --add-masquerade`
then `--reload`), required for the Tailscale exit-node and VMware
NAT egress paths to source-NAT traffic out the host's primary
interface, on top of the IPv4/IPv6 forwarding enabled by
`system/linux/etc/sysctl.d/99-tailscale.conf`. Gated on
`firewall-cmd --state` reporting firewalld is running, and idempotent
via `--permanent --query-masquerade`. Skipped cleanly when firewalld
is not the active backend (e.g. masked, missing, or replaced by raw
nftables / iptables-services).

## Layout

The path under `system/<os>/` mirrors the absolute install path exactly:

```
system/linux/etc/NetworkManager/conf.d/20-wifi-powersave-off.conf
            └── installs to /etc/NetworkManager/conf.d/20-wifi-powersave-off.conf
```

NetworkManager drop-ins under `system/linux/etc/NetworkManager/conf.d/` include
the consolidated unmanaged-device rules and a Wi-Fi default that disables power
saving for throughput/latency stability. Keep the unmanaged-device rules in
`99-unmanaged-devices.conf` — do not split them back out or consolidate them
further into a monolithic `NetworkManager.conf`.

| Subdirectory | Used for |
|---|---|
| `system/linux/etc/NetworkManager/conf.d/` | NetworkManager drop-ins for Wi-Fi power saving and unmanaged loopback, VMware, Tailscale, Podman (`podman*`), and veth interfaces |
| `system/linux/etc/keyd/` | keyd keyboard remapping defaults |
| `system/linux/etc/libinput/` | local libinput quirks |
| `system/linux/etc/locale.conf` | system locale |
| `system/linux/etc/modprobe.d/` | kernel module options, currently Bluetooth autosuspend disablement plus ThinkPad-only `thinkpad_acpi fan_control=1` for manual fan control |
| `system/linux/etc/modules-load.d/` | kernel modules loaded at boot, currently ThinkPad-only `thinkpad_acpi` |
| `system/linux/etc/plymouth/` | Plymouth boot splash config |
| `system/linux/etc/sudoers.d/` | password-less sudo drop-ins (mode `0440`, VM-only via `systemd-detect-virt --vm`) |
| `system/linux/etc/bluetooth/main.conf` | BlueZ daemon config (minimal); sets `Experimental = true` + `KernelExperimental = true` to enable Bluetooth LE Audio (BAP). `KernelExperimental` turns on the kernel ISO sockets BAP needs and has no bluetoothd command-line flag (main.conf only). Applies on the next `systemctl restart bluetooth` or reboot |
| `system/linux/etc/sysctl.d/` | sysctl drop-ins for forwarding and container network defaults |
| `system/linux/etc/udev/rules.d/` | udev rules, currently Logitech receiver permissions and NuPhy Gem80 VIA/WebHID access for Chromium |

There is currently no `system/macos/` or `system/windows/` tree. macOS settings usually belong under `home/` because they live in user-owned `~/Library` paths. Windows system config (registry tweaks, Group Policy, etc.) is **not** managed here — it doesn't fit the "drop a file at an absolute path" model. Add a `scripts/` helper if needed.

## `podman-docker` shim caveat

The `podman-docker` package ships `/usr/bin/docker` as a compatibility
shim that forwards to `podman`, which keeps `docker`-shaped CLIs
working out of the box. On a fresh install that is exactly what
you get. On a machine where Docker CE was previously installed,
`/usr/bin/docker` is still Docker CE's actual binary, and
**the shim is masked until Docker CE is manually removed**: dnf
refuses to overwrite the foreign package's file. The fix is to
uninstall the Docker CE packages first (`sudo dnf remove docker-ce
docker-ce-cli` plus any matching `containerd.io`), then install or
reinstall the shim (`sudo dnf install podman-docker`, or
`sudo dnf reinstall podman-docker` if it was already on disk), and
verify with `ls -l /usr/bin/docker` and `rpm -qf /usr/bin/docker`
(should report `podman-docker`, not `docker-ce`). The shim caveat
is independent of the `podman.socket` / `podman.service` mask above:
unmasking the shim only changes what `/usr/bin/docker` runs, it
does not expose the rootful socket.

See [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
