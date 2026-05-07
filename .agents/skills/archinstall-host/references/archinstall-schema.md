# archinstall JSON schema reference

Verified against [`archlinux/archinstall@b0b7983`](https://github.com/archlinux/archinstall/tree/b0b7983af2b0cabce282e576ed3a20010e20fb2c) (HEAD as of mid-2026). The docs in `archlinux/archinstall/docs/cli_parameters/config/` lag the source for several fields — when in doubt, source wins.

**Always regenerate, never hand-write:**

```bash
archinstall --dry-run
# walk the TUI, then:
cp /var/log/archinstall/user_configuration.json archinstall/<hostname>/user_configuration.json
```

[`guided.rst` confirms](https://github.com/archlinux/archinstall/blob/b0b7983af2b0cabce282e576ed3a20010e20fb2c/docs/installing/guided.rst#L46-L49) `--dry-run` is the canonical schema-regeneration path. Save dir is `/var/log/archinstall/`.

---

## Top-level keys (current canonical)

| Key | Required | Type | Notes |
|---|---|---|---|
| `version` | yes | string | archinstall release that produced this config (e.g. `"3.0.14"`) |
| `script` | yes | `null` or string | usually `null`; non-null selects an alternate script |
| `archinstall-language` | yes | string | TUI language, e.g. `"English"` |
| `hostname` | yes | string | system hostname |
| `kernels` | yes | `string[]` | e.g. `["linux"]`, `["linux-zen"]`, `["linux-lts"]` |
| `packages` | yes | `string[]` | top-level pacman packages added on top of `base` and profile/app additions |
| `services` | yes | `string[]` | systemd unit names enabled at install time |
| `custom_commands` | yes | `string[]` | shell snippets run in `arch-chroot` of the new system, after package install, before unmount |
| `ntp` | yes | bool | enable systemd-timesyncd |
| `timezone` | yes | string | IANA zone, e.g. `"Asia/Seoul"` |
| `pacman_config` | yes | object | `{ parallel_downloads, color }` |
| `swap` | yes | object | `ZramConfiguration { enabled, algorithm }` (legacy boolean still parses) |
| `locale_config` | yes | object | see below |
| `bootloader_config` | yes | object | see below |
| `disk_config` | yes | object | see below |
| `profile_config` | yes | object | see below |
| `mirror_config` | yes | object | see below |
| `network_config` | yes | object | see below |
| `app_config` | yes | object | see below |
| `auth_config` | yes | object | belongs in `user_credentials.json`, NOT in `user_configuration.json` |

Source: [`safe_config()` / `from_config()` in `args.py`](https://github.com/archlinux/archinstall/blob/b0b7983af2b0cabce282e576ed3a20010e20fb2c/archinstall/lib/args.py#L100-L134).

---

## `bootloader_config`

```json
{
  "bootloader": "Systemd-boot",
  "uki": true,
  "removable": false
}
```

Allowed `bootloader` values per [`Bootloader` enum](https://github.com/archlinux/archinstall/blob/b0b7983af2b0cabce282e576ed3a20010e20fb2c/archinstall/lib/models/bootloader.py#L10-L37):

- `"Systemd-boot"` — best for `sbctl` + UKI; what UX5606 uses
- `"Grub"` — works but more steps for Secure Boot
- `"Efistub"` / direct UKI — minimal
- `"Limine"` — works
- `"Refind"` — current source-only (docs lag)
- `"No bootloader"` — bring-your-own

`removable` only applies to `Grub`/`Limine` (write fallback path `/EFI/BOOT/BOOTX64.EFI`); `Systemd-boot` ignores it.

---

## `locale_config`

```json
{
  "kb_layout": "us",
  "sys_lang": "en_US.UTF-8",
  "sys_enc": "UTF-8",
  "console_font": "default8x16"
}
```

`kb_layout` is the TTY/X11 keyboard layout (`us`, `kr`, `de`, etc.).

---

## `pacman_config`

```json
{
  "parallel_downloads": 5,
  "color": true
}
```

Replaces the legacy top-level `parallel downloads` / `parallel_downloads` field.

---

## `swap`

Current model is **zram**, not partition swap or swapfile:

```json
{
  "enabled": true,
  "algorithm": "zstd"
}
```

For a btrfs swapfile (UX5606's approach), set `swap` to `false` and create the swapfile in a `custom_commands` block:

```bash
btrfs subvolume create /swap
btrfs filesystem mkswapfile --size 4g --uuid clear /swap/swapfile
echo '/swap/swapfile none swap defaults 0 0' >> /etc/fstab
```

There is **no first-class `swapfile` field** in archinstall today.

---

## `app_config`

Per [`application.py`](https://github.com/archlinux/archinstall/blob/b0b7983af2b0cabce282e576ed3a20010e20fb2c/archinstall/lib/models/application.py#L186-L247):

```json
{
  "audio_config": { "audio": "pipewire" },
  "bluetooth_config": { "enabled": true },
  "power_management_config": { "power_management": "power-profiles-daemon" },
  "print_service_config": { "enabled": true },
  "firewall_config": { "firewall": "ufw" },
  "fonts_config": { "fonts": ["noto-fonts", "noto-fonts-emoji"] }
}
```

`audio_config.audio` accepts: `"pipewire"`, `"pulseaudio"`, `"No audio server"`.

`power_management.power_management` accepts: `"power-profiles-daemon"`, `"tuned"`.

`firewall_config.firewall` accepts: `"ufw"`, `"firewalld"`, etc.

The legacy top-level `audio_config` (peer of `app_config`) is still parsed for backward compatibility; new configs MUST use the nested form.

---

## `auth_config`

Lives in `user_credentials.json`, **not** in `user_configuration.json`:

```json
{
  "root_enc_password": "$y$j9T$...",
  "users": [
    { "username": "h82", "enc_password": "$y$j9T$...", "sudo": true, "groups": [] }
  ],
  "u2f_config": { "u2f_login_method": "passwordless", "passwordless_sudo": true }
}
```

Plus the LUKS passphrase as a sibling key in `user_credentials.json`:

```json
"!encryption-password": "<plain-luks-passphrase>"
```

Hash passwords with `mkpasswd -m yescrypt`. **Never** commit this file — `archinstall/*/user_credentials.json` is in [`.gitignore`](../../../.gitignore).

---

## `network_config`

```json
{ "type": "nm" }
```

Allowed `type` values per [`network.py`](https://github.com/archlinux/archinstall/blob/b0b7983af2b0cabce282e576ed3a20010e20fb2c/archinstall/lib/models/network.py#L100-L134):

- `"nm"` — NetworkManager (best default for laptops, what UX5606 + t14-gen2 use)
- `"iwd"` — minimal Wi-Fi only
- `"nm_iwd"` — NetworkManager backed by iwd (note: serialization may not round-trip; verify with `--dry-run`)
- `"manual"` — bring-your-own (`networkd`, `dhcpcd`, etc.)
- `"iso"` — copy the ISO's network config (rarely useful post-install)

For `nm_iwd` setups, check `cat /sys/class/net/wlan0/uevent` after install.

---

## `mirror_config`

```json
{
  "mirror_regions": {
    "South Korea": [
      "https://mirror.example.kr/archlinux/$repo/os/$arch"
    ]
  },
  "optional_repositories": ["multilib"],
  "custom_repositories": [],
  "custom_servers": []
}
```

`optional_repositories` is the new name for legacy `additional-repositories`. Use `["multilib"]` for 32-bit packages (Steam, Wine, lib32-vulkan-radeon).

Per [`mirrors.py`](https://github.com/archlinux/archinstall/blob/b0b7983af2b0cabce282e576ed3a20010e20fb2c/archinstall/lib/models/mirrors.py#L231-L263).

---

## `profile_config`

```json
{
  "profile": {
    "main": "Desktop",
    "details": ["KDE Plasma"],
    "custom_settings": { "KDE Plasma": {} }
  },
  "gfx_driver": "Intel (open-source)",
  "greeter": "sddm"
}
```

`gfx_driver` per [`profile.py`](https://github.com/archlinux/archinstall/blob/b0b7983af2b0cabce282e576ed3a20010e20fb2c/archinstall/lib/models/profile.py#L40-L50):

- `"Intel (open-source)"`
- `"AMD / ATI (open-source)"`
- `"Nvidia open-kernel"`
- `"Nouveau"`
- `"VMware / VirtualBox"`
- `"All (open-source)"`
- proprietary NVIDIA: explicitly **rejected** by current source — use `"Nvidia open-kernel"`

`profile.main` examples: `"Desktop"`, `"Server"`, `"Minimal"`, `"Xorg"`.
`profile.details` for desktops: `"KDE Plasma"`, `"GNOME"`, `"Sway"`, `"i3"`, `"Hyprland"`, `"Cinnamon"`, `"Mate"`, `"Xfce"`, `"Awesome"`, etc.

`greeter` (display manager): `"sddm"`, `"gdm"`, `"lightdm-gtk-greeter"`, `"ly"`.

---

## `disk_config`

```json
{
  "config_type": "manual_partitioning",
  "device_modifications": [
    { "device": "/dev/nvme0n1", "wipe": true, "partitions": [...] }
  ],
  "disk_encryption": { ... },
  "lvm_config": null,
  "btrfs_options": { "snapshot_config": { "type": "Snapper" } }
}
```

`config_type`:
- `"default_layout"` — archinstall picks
- `"manual_partitioning"` — full schema below
- `"pre_mounted_config"` — assume the user has already mounted everything

Per [`disk_config.rst`](https://github.com/archlinux/archinstall/blob/b0b7983af2b0cabce282e576ed3a20010e20fb2c/docs/cli_parameters/config/disk_config.rst#L6-L90) and [`device.py`](https://github.com/archlinux/archinstall/blob/b0b7983af2b0cabce282e576ed3a20010e20fb2c/archinstall/lib/models/device.py#L47-L79).

### Partition object

```json
{
  "obj_id": "uuid-or-label",
  "status": "create",
  "type": "primary",
  "start": { "value": 1, "unit": "MiB", "sector_size": null },
  "size":  { "value": 1, "unit": "GiB", "sector_size": null },
  "fs_type": "fat32",
  "mountpoint": "/boot",
  "mount_options": [],
  "flags": ["boot", "esp"],
  "dev_path": null,
  "btrfs": []
}
```

Fields per [`PartitionModification.json()`](https://github.com/archlinux/archinstall/blob/b0b7983af2b0cabce282e576ed3a20010e20fb2c/archinstall/lib/models/device.py#L832-L1043):

- `status`: `existing` | `modify` | `delete` | `create`
- `type`: `primary` | `boot`
- `flags`: `boot`, `esp`, `xbootldr`, `linux-home`, `swap`
- `fs_type`: `fat32`, `ext4`, `btrfs`, `xfs`, `f2fs`, `linux-swap`, `ntfs`

### Btrfs subvolumes

```json
"btrfs": [
  { "name": "@",         "mountpoint": "/" },
  { "name": "@home",     "mountpoint": "/home" },
  { "name": "@log",      "mountpoint": "/var/log" },
  { "name": "@cache",    "mountpoint": "/var/cache" },
  { "name": "@snapshots", "mountpoint": null }
]
```

When using btrfs subvolumes, leave the partition's own `mountpoint` as `null` — subvolumes carry the mountpoints.

### LUKS encryption (canonical nested form)

```json
"disk_encryption": {
  "encryption_type": "luks",
  "partitions": ["<partition obj_id>"],
  "lvm_volumes": [],
  "iter_time": 10000
}
```

Legacy top-level `disk_encryption` is still parsed for backward compat; new configs nest under `disk_config`.

The actual passphrase lives in `user_credentials.json` as `!encryption-password`.

---

## Legacy keys still accepted

archinstall parses these for backward compat but they're not the canonical form:

| Legacy key | Current replacement |
|---|---|
| top-level `audio_config` | `app_config.audio_config` |
| top-level `disk_encryption` | `disk_config.disk_encryption` |
| top-level `bootloader` / `uki` | `bootloader_config.{bootloader, uki}` |
| `additional-repositories` | `mirror_config.optional_repositories` |
| `parallel downloads` / `parallel_downloads` | `pacman_config.parallel_downloads` |
| `!root-password` | `auth_config.root_enc_password` (in credentials) |
| top-level `users` | `auth_config.users` (in credentials) |

UX5606's [`user_configuration.json`](../../../archinstall/UX5606/user_configuration.json) uses the canonical nested forms throughout.

---

## What is NOT in the schema

- **No `additional_packages` field**: use `packages`, `app_config` additions, `profile_config` profile-driven packages, or `custom_commands` `pacman -S` calls.
- **No `swapfile` first-class config**: do it in `custom_commands` (UX5606 pattern).
- **No proprietary NVIDIA driver**: archinstall rejects `"Nvidia (proprietary)"`. Use `"Nvidia open-kernel"` and add packages explicitly if you must.

---

## CPU microcode auto-detect

archinstall auto-adds `intel-ucode` or `amd-ucode` based on `/proc/cpuinfo` Vendor ID, skipping in VMs. Source: [`hardware.py`](https://github.com/archlinux/archinstall/blob/b0b7983af2b0cabce282e576ed3a20010e20fb2c/archinstall/lib/hardware.py#L14-L37). You can also list the package explicitly in `packages` to make the choice visible in the config.

---

## GPU driver auto-injection

When `profile_config.gfx_driver` is set, archinstall injects matching packages per [`hardware.py`](https://github.com/archlinux/archinstall/blob/b0b7983af2b0cabce282e576ed3a20010e20fb2c/archinstall/lib/hardware.py#L40-L140):

| `gfx_driver` | Injected packages |
|---|---|
| `Intel (open-source)` | `mesa`, `libva-intel-driver`, `intel-media-driver`, `vulkan-intel` |
| `AMD / ATI (open-source)` | `mesa`, `xf86-video-amdgpu`, `xf86-video-ati`, `vulkan-radeon` |
| `Nvidia open-kernel` | `nvidia-open-dkms`, `dkms`, `libva-nvidia-driver` (or `nvidia-open` when all kernels are mainline) |
| `Nouveau` | `mesa`, `xf86-video-nouveau`, `vulkan-nouveau` |
