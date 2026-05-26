# system/

Root-owned config that ships to absolute system paths (`/etc/...`, etc.).

dotbot has no root-aware mode and no sudo handling, so these files are **NOT** installed via `link:`. They are installed by `shell:` steps in the matching `install.<os>.yaml` calling:

```sh
sudo install -D -m <mode> system/<os>/<abs/path> /<abs/path>
```

`install -D` is the only correct tool here — it sets mode atomically and creates parent directories. **Don't** use `sudo cp` (no atomic mode/owner) and **don't** try to express these as dotbot `link:` blocks (no sudo support).

Linux system files are discovered recursively under `system/linux/etc/` and
installed with mode `0644` by default. The one exception is
`system/linux/etc/sudoers.d/*`, which the installer ships at mode `0440`
(sudo refuses group/world-readable drop-ins) and only when
`systemd-detect-virt --vm` reports a virtual machine — never on bare-metal
hosts. Drop-in contents are syntax-checked with `visudo -c -f` before
install. Adding files outside `sudoers.d/` should not require editing the
installer unless they need a different mode or a platform/host gate.

After file install, the installer runs `systemctl daemon-reload`
when `system/linux/etc/systemd/system/` exists and enables
`docker-prune.timer` with `systemctl enable --now` (gated on
`command -v docker` so hosts without docker stay clean). It then
enables firewalld IPv4 masquerading on the default zone (`firewall-cmd --permanent
--add-masquerade` then `--reload`) — required for the Tailscale
exit-node and VMware NAT egress paths to source-NAT traffic out the
host's primary interface, on top of the IPv4/IPv6 forwarding enabled
by `system/linux/etc/sysctl.d/99-tailscale.conf`. Gated on
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
| `system/linux/etc/NetworkManager/conf.d/` | NetworkManager drop-ins for Wi-Fi power saving and unmanaged loopback, VMware, Tailscale, Docker, and veth interfaces |
| `system/linux/etc/keyd/` | keyd keyboard remapping defaults |
| `system/linux/etc/libinput/` | local libinput quirks |
| `system/linux/etc/locale.conf` | system locale |
| `system/linux/etc/plymouth/` | Plymouth boot splash config |
| `system/linux/etc/sudoers.d/` | password-less sudo drop-ins (mode `0440`, VM-only via `systemd-detect-virt --vm`) |
| `system/linux/etc/systemd/system/` | system-scope systemd units, currently `docker-prune.service` + `docker-prune.timer` (weekly `docker system prune --force` and `docker volume prune --force`; enabled by the installer when `docker` is present, with `ConditionPathExists=/usr/bin/docker` as runtime safety net) |
| `system/linux/etc/sysctl.d/` | sysctl drop-ins for forwarding and container network defaults |
| `system/linux/etc/udev/rules.d/` | udev rules, currently Logitech receiver permissions |

There is currently no `system/macos/` or `system/windows/` tree. macOS settings usually belong under `home/` because they live in user-owned `~/Library` paths. Windows system config (registry tweaks, Group Policy, etc.) is **not** managed here — it doesn't fit the "drop a file at an absolute path" model. Add a `scripts/` helper if needed.

See [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
