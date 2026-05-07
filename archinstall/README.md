# archinstall/

Arch Linux unattended provisioning. Each host has its own subdirectory under `archinstall/<hostname>/`.

The reproducible procedure for adding a new host lives in the [`archinstall-host`](../.agents/skills/archinstall-host/SKILL.md) skill. Load it with `skill(name="archinstall-host")` when adding or testing a host.

## Layout

```
archinstall/
├── README.md                        # This file
├── post-install.sh                  # Hook: clone+bootstrap dotfiles after install
├── inspect-hardware.sh              # Per-machine hardware reporter (maps to archinstall knobs)
├── test-host.sh                     # Burnable QEMU+OVMF+swtpm test harness with DMI auto-detect
├── user_credentials.example.json    # Schema reference (only credentials file in git)
└── <hostname>/
    ├── user_configuration.json      # Disk, profile, packages, custom_commands
    ├── user_credentials.json        # GITIGNORED — passwords + LUKS keys
    ├── host-metadata.json           # DMI fingerprint for test-host.sh auto-detect (tracked)
    ├── *secureboot*.service         # Optional host first-boot services
    ├── *secureboot*.sh              # Optional host first-boot helpers
    └── initialize*.sh               # Optional host-specific legacy/manual scripts
```

## Bootstrap from the Arch live ISO

```sh
# 1. Get network on the live ISO (iwctl / dhcp / etc.)
# 2. Copy your host's configs onto the live system (USB, scp, curl, ...)
# 3. Run archinstall in silent mode:
archinstall \
  --config archinstall/<hostname>/user_configuration.json \
  --creds  archinstall/<hostname>/user_credentials.json \
  --silent
```

archinstall provisions the system, then runs `custom_commands` (defined in `user_configuration.json`) in `arch-chroot` of the new system before unmount. Those `custom_commands` end by invoking [`post-install.sh`](./post-install.sh), which clones this repo and runs `install.sh`. First boot lands on a fully linked system.

## Hosts

| Host | Hardware | DMI auto-detect | Notes |
|---|---|---|---|
| `UX5606` | ASUS Zenbook UX5606 | (no `host-metadata.json` yet — add to enable auto-detect) | Migrated from `~/nix-config/dotfiles-legacy/archinstall/`. `user_configuration.json` embeds the host post-install automation directly in `custom_commands`: enable KDE/desktop services, create the Btrfs swapfile, configure SDDM Wayland, clone this repo, run `install.sh`, and install the first-boot Secure Boot/TPM systemd service. Credentials stay local in `archinstall/UX5606/user_credentials.json`. `initialize*.sh` are retained as host-specific/manual legacy scripts. |
| `t14-gen2` | Lenovo ThinkPad T14 Gen 2 (Intel) | `host-metadata.json` matches `LENOVO / "ThinkPad T14*Gen 2*"` ([wiki](https://wiki.archlinux.org/title/Lenovo_ThinkPad_T14/T14s_(Intel)_Gen_2)) | T14 Gen 2 daily driver. Built via the [`archinstall-host`](../.agents/skills/archinstall-host/SKILL.md) skill. T14 Gen 2 specifics: Intel `intel-ucode`, Iris Xe (`Intel (open-source)` driver, `mesa vulkan-intel intel-media-driver`), AX201 Wi-Fi, Bluetooth `8087:0026`, **REQUIRED `sof-firmware`** for Intel SOF audio, fingerprint reader `06CB:00F9`, `power-profiles-daemon` for laptop power, fwupd with LVFS testing remote for firmware updates. First-boot service `t14-gen2-secureboot-tpm-enroll.service` runs sbctl key enrollment (Setup Mode required) + signs systemd-boot/UKI + binds TPM2 LUKS unlock to PCR 7. Locale `ko_KR.UTF-8`, mirror set to Arch's geo mirror after multiple KR mirrors served mismatched `libnotify` signatures during validation, KDE Plasma + sddm + pipewire. See [`t14-gen2/README.md`](./t14-gen2/README.md) for the physical install procedure. The tracked config does not include a physical `disk_config`; choose the real disk in the TUI or generate a machine-local silent config before installing. |

## inspect-hardware.sh — hardware reporter

Run on the target machine to produce a Markdown report that maps detected hardware to archinstall config decisions:

```sh
archinstall/inspect-hardware.sh                # print to stdout
archinstall/inspect-hardware.sh -o report.md   # write to file
sudo archinstall/inspect-hardware.sh -o ...    # full DMI / BIOS / chassis output
```

The report includes a "DMI fingerprint" section with a ready-to-paste `host-metadata.json` skeleton populated with the running machine's actual values. See the [`archinstall-host` skill](../.agents/skills/archinstall-host/SKILL.md), Phase 2.

Linux-only by design (per-AGENTS.md single-platform exception).

## test-host.sh — burnable QEMU validation harness

Spins up a disposable QEMU VM that mimics a physical UEFI box with Secure Boot, LUKS, and TPM2:

```sh
archinstall/test-host.sh                        # auto-detect hostname via DMI, manual drive
archinstall/test-host.sh <hostname>             # explicit hostname, manual drive
archinstall/test-host.sh <hostname> --drive     # provision + auto-drive archinstall to completion
archinstall/test-host.sh --drive-only [<host>]  # drive a previously-provisioned VM
archinstall/test-host.sh --boot-installed [<host>] # boot existing installed qcow2 (no ISO/direct kernel)
archinstall/test-host.sh --detect               # print DMI-auto-detected hostname (or exit 1)
archinstall/test-host.sh --cleanup [<hostname>] # tear down (auto-detects if hostname omitted)
archinstall/test-host.sh --list                 # list active test sessions
archinstall/test-host.sh --help                 # full flag reference
```

What `provision` does:

1. Detects `edk2-ovmf` paths (Arch / Debian / Fedora / NixOS layouts).
2. Allocates `~/.cache/archinstall-host/state/<hostname>-<timestamp>/`.
3. Copies `OVMF_VARS.4m.fd` (writable per-VM, blank → firmware boots in Setup Mode for sbctl key enrollment from inside the guest).
4. Provisions a fresh qcow2 disk + initialises `swtpm` software TPM 2.0.
5. Downloads or reuses the latest Arch ISO from `~/.cache/archinstall-host/iso/` (KR mirrors prioritized, override via `ARCHINSTALL_HOST_ISO_MIRROR`).
6. **Direct kernel boot**: extracts `vmlinuz-linux` + `initramfs-linux.img` from the ISO and boots them with `console=ttyS0,115200` on the kernel cmdline. This bypasses GRUB, so the live ISO comes up immediately on the serial console — no menu-timer race. (Pass `--no-direct-boot` to fall back to legacy `-cdrom` + GRUB if needed.)
7. Mounts the host config dir at `/mnt/host` (RO) and the state dir at `/mnt/state` (RW) via virtio-9p. **Important:** after `archinstall` mounts the target root on `/mnt`, those 9p mounts are buried. Use them only before `archinstall` starts, or paste/recover files another way.
8. Generates a test-only `disk_config` template at `state_dir/test-disk-config.json` for `/dev/nvme0n1` with LUKS+btrfs (4 subvols: `@`, `@home`, `@log`, `@snapshots`). Computed for `--disk` size; defaults to 40 GiB → 1 GiB EFI + 38 GiB encrypted root.
9. Starts QEMU in q35 + SMM-on + Secure-Boot-capable mode with serial → tmux pane.

### Manual drive (no `--drive`)

```sh
tmux attach -t archinstall-host-<hostname>
# log in as root over serial (live ISO autologin only fires on tty1, not ttyS0)
# the live ISO root password is empty — just `root\n`
mount -t 9p -o trans=virtio,version=9p2000.L,ro host0 /mnt/host
mount -t 9p -o trans=virtio,version=9p2000.L     state0 /mnt/state
jq -s '.[0] * .[1]' /mnt/host/user_configuration.json /mnt/state/test-disk-config.json \
  > /mnt/state/merged-config.json
archinstall --config /mnt/state/merged-config.json --creds /mnt/host/user_credentials.json --silent
reboot
```

### Auto-drive (`--drive`)

`--drive` runs the full sequence above non-interactively via `tmux send-keys`, polling the pane for known prompts. After provisioning it:

1. Waits for the `archiso login:` prompt, sends `root\n`.
2. Mounts both 9p shares.
3. Merges `user_configuration.json` with `test-disk-config.json` via `jq`.
4. Runs `archinstall --silent` (with `set -o pipefail` so a tee'd pipe doesn't mask non-zero exits).
5. Watches for the `__AI_RC=<digit>` sentinel (timeout `--drive-timeout`, default 1800 s).
6. Powers off the live ISO and relaunches QEMU with the same qcow2 + OVMF VARS + TPM state, but **without** `-kernel`/`-initrd` and without the ISO. Direct kernel boot is only for the live installer; installed-system verification must boot through UEFI/systemd-boot.
7. Waits for the LUKS prompt.
8. Sends the `!encryption-password` from `user_credentials.json` to unlock the disk.
9. Confirms the installed-system login prompt appears.

Logs land in `~/.cache/archinstall-host/state/<hostname>-<ts>/archinstall.log` for offline forensics.

If `custom_commands` clone this repo and then install host-specific files (for example first-boot Secure Boot services), those files must be committed and reachable from the clone. A VM does **not** see local-only files unless you explicitly paste/recover them. `test-host.sh` warns when host `.sh` / `.service` files are untracked or dirty and the config appears to clone dotfiles.

Mirror quality matters more than country membership. During the `t14-gen2` VM test, stale or slow Korean mirrors caused late `pacstrap` failures after 40–60 minutes (`404` for current packages, `Operation too slow`, and package/signature mismatches when multiple mirrors were mixed). Keep host mirror lists restricted to currently-synced HTTPS mirrors verified with package + signature HEAD requests. For burnable validation, prefer a single known-synced mirror over every mirror in the country list.

When `custom_commands` run the dotfiles bootstrap as the target user, install an explicit per-user `NOPASSWD` sudoers rule before invoking `install.sh`. Relying on `%wheel` can still prompt in the chroot/non-interactive path and fail root-owned config installation.

Use `--boot-installed <host>` when a previous run already installed the qcow2 and you only need to re-test the installed-system boot path. It reuses the existing state directory, restarts `swtpm` if needed, and launches QEMU without the ISO/direct-kernel boot path.

### After reboot, verify Secure Boot + TPM2

```sh
bootctl status; sbctl status
systemd-cryptenroll --tpm2-device=list
cryptsetup luksDump <LUKS_DEVICE> | grep tpm2
```

When done: `archinstall/test-host.sh --cleanup <hostname>`.

Hard requirements: `qemu-full` (or `qemu-base + qemu-system-x86`), `edk2-ovmf`, `swtpm`, `tmux`, `curl`, `jq`, `libarchive` (`bsdtar`, used to extract kernel+initrd from ISO for direct boot). KVM strongly recommended (`--no-kvm` for TCG fallback).

NixOS shorthand: `nix shell nixpkgs#libarchive nixpkgs#jq nixpkgs#swtpm --command archinstall/test-host.sh <hostname> --drive`.

Linux-only by design.

## host-metadata.json — DMI auto-detect

Each host SHOULD ship a `host-metadata.json` so `test-host.sh` can:

- **Auto-select** the right config when run on a matching machine (no need to type the hostname)
- **Validate** (warn-only) when the user passes a hostname that mismatches the running hardware

Schema (tracked in git):

```json
{
  "$schema": "host-metadata.v1",
  "hostname": "t14-gen2",
  "description": "Lenovo ThinkPad T14 Gen 2 (Intel) — daily driver",
  "archwiki_page": "https://wiki.archlinux.org/title/Lenovo_ThinkPad_T14/T14s_(Intel)_Gen_2",
  "dmi_match": {
    "sys_vendor":      "LENOVO",
    "product_version": "ThinkPad T14*Gen 2*"
  }
}
```

Fields under `dmi_match` are glob patterns (`*`, `?`) compared against `/sys/class/dmi/id/<field>` (no root needed). Empty / missing fields are wildcards. Match is AND across fields. Auto-detect succeeds only when exactly one host matches the running machine.

`inspect-hardware.sh` prints the running machine's DMI values + a ready-to-paste skeleton — copy it into the new host directory, glob-loosen as needed (prefer `product_version` over per-SKU `product_name`), commit.

## UX5606 Secure Boot + TPM enrollment

The UX5606 config installs and enables `ux5606-secureboot-tpm-enroll.service` for first boot. The service runs [`secureboot-tpm-enroll.sh`](./UX5606/secureboot-tpm-enroll.sh), which uses `sbctl` to create/enroll keys only when firmware is in Setup Mode, signs existing systemd-boot/UKI artifacts, then uses `systemd-cryptenroll` to enroll the root LUKS device with TPM2 bound to PCR 7.

TPM enrollment is semi-automated by design: the service asks for the existing LUKS passphrase through `systemd-ask-password` instead of storing disk secrets in git or in `user_configuration.json`. Keep a recovery passphrase/key available before relying on TPM unlock.

## post-install.sh

Designed for two callers:

1. **archinstall `custom_commands`** — runs as root inside `arch-chroot`. Pass the target username as `$1`.
2. **Manual re-run** on a freshly-installed Arch box (e.g. provisioned by another method). Same invocation.

Recommended `custom_commands` entry in `user_configuration.json`:

```json
"custom_commands": [
  "curl -fsSL https://raw.githubusercontent.com/hyperlapse122/dotfiles/main/archinstall/post-install.sh | bash -s -- <username>"
]
```

`<username>` MUST match `users[*].username` from `user_credentials.json`.

## Regenerating `user_configuration.json`

archinstall's JSON schema changes between releases. **Don't hand-edit fields you don't understand.** Regenerate:

```sh
archinstall --dry-run
# Walk through the TUI, then copy the produced config out:
cp /var/log/archinstall/user_configuration.json archinstall/<hostname>/user_configuration.json
```

The parser still accepts legacy keys (`audio_config`, `bootloader`, `!root-password`), but new configs SHOULD use the current nested shape (`disk_config`, `bootloader_config`, `auth_config`, `app_config`).

## Credentials

`user_credentials.json` is **gitignored** (see root `.gitignore`). Only [`user_credentials.example.json`](./user_credentials.example.json) is tracked.

Generate password hashes with:

```sh
mkpasswd -m yescrypt        # for root_enc_password and users[*].enc_password
```

`!encryption-password` (LUKS passphrase) is a plain string. Treat it as the most sensitive value in the file — losing it means losing the disk.

See [`AGENTS.md`](../AGENTS.md) for the full contract.
