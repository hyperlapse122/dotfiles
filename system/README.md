# system/

Root-owned config that ships to absolute system paths (`/etc/...`, etc.).

dotbot has no root-aware mode and no sudo handling, so these files are **NOT** installed via `link:`. They are installed by `shell:` steps in the matching `install.<os>.yaml` calling:

```sh
sudo install -D -m <mode> system/<os>/<abs/path> /<abs/path>
```

`install -D` is the only correct tool here — it sets mode atomically and creates parent directories. **Don't** use `sudo cp` (no atomic mode/owner) and **don't** try to express these as dotbot `link:` blocks (no sudo support).

Linux system files are discovered recursively under `system/linux/etc/` and
installed with mode `0644`. Adding or removing a file there should not require
editing the installer unless that file needs a different mode.

## Layout

The path under `system/<os>/` mirrors the absolute install path exactly:

```
system/linux/etc/NetworkManager/conf.d/wifi-powersave-off.conf
            └── installs to /etc/NetworkManager/conf.d/wifi-powersave-off.conf
```

NetworkManager drop-ins under `system/linux/etc/NetworkManager/conf.d/` mirror
the legacy dotfiles layout. Keep per-interface unmanaged-device rules as split
drop-in files — do not consolidate them into a monolithic `NetworkManager.conf`.

| Subdirectory | Used for |
|---|---|
| `system/linux/` | Linux-only `/etc/...` and similar |
| `system/macos/` | macOS-only system paths (rarely needed; most macOS settings live under `~/Library` and belong in `home/`) |

Windows system config (registry tweaks, Group Policy, etc.) is **not** managed here — it doesn't fit the "drop a file at an absolute path" model. Add a `scripts/` helper if needed.

See [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
