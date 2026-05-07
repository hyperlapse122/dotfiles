---
name: archinstall-host
description: Creates and validates a new Arch Linux host configuration under archinstall/<hostname>/ for unattended provisioning, with reproducible steps. Use when the user asks to add a new archinstall host, generate user_configuration.json for a new machine, set up Arch on a new laptop or desktop, port a host config from another tree, or test/validate an existing archinstall config in a VM. The skill drives ArchWiki research for hardware-specific packages and quirks (laptop model pages, CPU microcode, GPU/audio/network drivers), uses the host's own lspci/lsusb/dmidecode when the target matches the current machine, and tests every config in a disposable QEMU VM that mimics a physical UEFI box with Secure Boot, LUKS full-disk encryption, and TPM2 enrollment before declaring done.
license: MIT
metadata:
  audience: maintainers
  workflow: arch-linux-provisioning
---

# archinstall-host

Reproducible procedure for adding a new Arch Linux host to `archinstall/<hostname>/` in this dotfiles repo, plus burnable QEMU validation. **Every step has a tool or a script — no hand-waving, no untested configs.**

## When to load this skill

Load on intents like:
- "create a new arch host config"
- "add a host to archinstall/"
- "generate user_configuration.json for <machine>"
- "set up archinstall for my new laptop"
- "test the existing UX5606 config in a VM"
- "port my old archinstall config to this repo"

## Do not load when

- Just editing an existing host's packages list — use `Edit` directly.
- Just regenerating a single field — `archinstall --dry-run` and copy the value.
- Modifying `archinstall/post-install.sh` — that script is shared across all hosts; the skill is per-host.

## Hard contract

Before declaring done you MUST:

1. **Produce `archinstall/<hostname>/user_configuration.json`** that matches the current archinstall schema. Generate it with `archinstall --dry-run`, never hand-write the schema. See [`references/archinstall-schema.md`](references/archinstall-schema.md).
2. **Produce `archinstall/<hostname>/user_credentials.json`** locally only. It is gitignored. Treat the LUKS passphrase as the most sensitive value.
3. **Pass `archinstall/test-host.sh <hostname>`** in a burnable QEMU VM with UEFI Secure Boot + TPM2 enabled. The full archinstall must complete and the installed system must boot. See [`references/qemu-test-harness.md`](references/qemu-test-harness.md).
4. **Document the host** in [`archinstall/README.md`](../../../archinstall/README.md) "Hosts" table.
5. **Do not commit** unless the user explicitly asks.

`lsp_diagnostics` does NOT validate JSON archinstall semantics. Only `archinstall --dry-run` and the QEMU test do.

## Six-phase procedure

### Phase 1 — Decide scope

Ask if not given:

- **Hostname** — short, lowercase, kebab-case preferred (`t14-gen2`, `nuc-server-01`). Becomes the directory name AND `hostname` in the JSON.
- **Target machine identity** — vendor + model + generation. Used to pick the ArchWiki page.
- **Same hardware as current host?** — if yes, run `archinstall/inspect-hardware.sh` to get authoritative driver/microcode info.
- **Physical UEFI box or VM?** — physical → enable Secure Boot + TPM2; VM → simpler config, skip the first-boot enrollment service.
- **Encryption?** — LUKS full-disk is the default and what `test-host.sh` validates. Skip only if user explicitly says no.

### Phase 2 — Gather hardware facts

Two paths, depending on Phase 1:

#### Path A: target machine == current host

```bash
archinstall/inspect-hardware.sh -o /tmp/hardware-report.md
```

Report sections map to archinstall knobs (CPU vendor → microcode, GPU vendor → `profile_config.gfx_driver` + packages, etc.). The script also checks bootloader, Secure Boot status, TPM2 presence, and current LUKS state.

#### Path B: target machine != current host (or no access)

Ask the user for vendor/model. Then **fetch the ArchWiki model page** to get the canonical hardware ID table and quirks. Examples of model page URL patterns:

- `https://wiki.archlinux.org/title/Lenovo_ThinkPad_T14/T14s_(Intel)_Gen_2`
- `https://wiki.archlinux.org/title/ASUS_Zenbook_UX5606`
- `https://wiki.archlinux.org/title/Framework_Laptop_13_(AMD_Ryzen_AI_300_Series)`

If the model page exists, extract:
- The hardware ID table (USB/PCI vendor:product → component)
- Suspend caveats (S0ix vs S3, broken kernel versions)
- Audio quirks (e.g. Sound Open Firmware required → `sof-firmware`)
- Graphics/firmware special packages
- Mobile broadband / fingerprint reader / dock specifics
- Function keys and keyboard backlight

Cross-reference with [`references/archwiki-pages.md`](references/archwiki-pages.md) for general topic pages (CPU microcode, NVIDIA, PipeWire, Bluetooth, fwupd, etc.).

### Phase 3 — Generate `user_configuration.json`

**Never hand-write the schema.** archinstall's nested config format changes between releases. Generate it on the target machine OR on any Arch host:

```bash
archinstall --dry-run
# Walk the TUI — pick disk layout, encryption, bootloader, locale, packages.
# When done, --dry-run writes the JSON to /var/log/archinstall/user_configuration.json.
cp /var/log/archinstall/user_configuration.json archinstall/<hostname>/user_configuration.json
```

If the target host has no booted Arch yet, do the dry-run from the live ISO or from inside the QEMU test VM (boot the ISO with `archinstall/test-host.sh <hostname-tmp>`, run `archinstall --dry-run`, scp the result back).

After generation, edit the file to apply hardware decisions from Phase 2. See [`references/archinstall-schema.md`](references/archinstall-schema.md) for the current top-level shape and per-section field reference. Key knobs:

| Knob | Driven by |
|---|---|
| `bootloader_config.bootloader` | `Systemd-boot` (best for sbctl + UKI), or `Grub` |
| `bootloader_config.uki` | `true` for measured boot via UKI |
| `disk_config.disk_encryption` | LUKS encryption_type, partition obj_ids |
| `app_config.audio_config.audio` | `pipewire` (default), `pulseaudio` |
| `app_config.bluetooth_config.enabled` | from inspect-hardware report |
| `app_config.power_management_config.power_management` | `power-profiles-daemon` for laptops |
| `network_config.type` | `nm` (NetworkManager — default), `iwd`, `nm_iwd`, `manual`, `iso` |
| `profile_config.gfx_driver` | `Intel (open-source)`, `AMD / ATI (open-source)`, `Nvidia open-kernel`, `Nouveau`, `VMware / VirtualBox` |
| `profile_config.profile` | `KDE Plasma`, `GNOME`, `Sway`, `i3`, `Hyprland`, `Server`, `Minimal`, etc. |
| `packages` | `intel-ucode` OR `amd-ucode`; model-specific extras (`sof-firmware`, `fprintd`, `fwupd`, etc.) |
| `kernels` | `linux` default; `linux-zen` for desktop responsiveness; `linux-lts` for stability |
| `mirror_config.mirror_regions` | regional mirror set |
| `locale_config` | `kb_layout`, `sys_lang`, `sys_enc` |
| `timezone` | IANA zone (`Asia/Seoul`, `America/Los_Angeles`) |
| `services` | systemd unit names enabled at install time |
| `custom_commands` | inline heredoc OR `curl ... | bash post-install.sh <username>` |

### Phase 3.5 — Write `host-metadata.json` for DMI auto-detect

Every host SHOULD have an `archinstall/<hostname>/host-metadata.json` file so `archinstall/test-host.sh` can:

- **Auto-select** the right host config when run on a machine that matches (no need to type the hostname).
- **Validate** (warn-only) when the user passes a hostname that mismatches the running hardware.

Schema:

```json
{
  "$schema": "host-metadata.v1",
  "hostname": "t14-gen2",
  "description": "Lenovo ThinkPad T14 Gen 2 (Intel) — T14 Gen 2 daily driver",
  "archwiki_page": "https://wiki.archlinux.org/title/Lenovo_ThinkPad_T14/T14s_(Intel)_Gen_2",
  "dmi_match": {
    "sys_vendor":      "LENOVO",
    "product_version": "ThinkPad T14*Gen 2*"
  }
}
```

Rules:
- All fields under `dmi_match` are **glob patterns** (`*`, `?`) compared against `/sys/class/dmi/id/<field>`.
- **Missing or empty fields are wildcards.** A `dmi_match` of `{}` matches everything (don't do that).
- Match is **AND across fields**: every specified field must glob-match.
- Match is **per-host**: auto-detect only succeeds when exactly one host metadata matches the running machine.
- `/sys/class/dmi/id/*` is **readable without root** for the fields we care about — no `sudo` needed.

**Field-selection guidance:**
- **Always include `sys_vendor`** (`LENOVO`, `ASUSTeK COMPUTER INC.`, `Dell Inc.`, `HP`, `Framework`, `System76`, etc.).
- **Prefer `product_version` over `product_name` for laptops.** `product_name` is per-SKU (e.g. `20W1S5DL0H`, `20XK000FKR`); `product_version` is the human model string and stable across SKUs (`ThinkPad T14 Gen 2i`).
- **Use `board_name` for desktops/NUCs** when `product_name` is empty or generic.
- **Combine narrowly only when SKU matters** (e.g. distinguishing AMD vs Intel variants of the same model line).

Get the canonical fingerprint values via `archinstall/inspect-hardware.sh` — its "DMI fingerprint" section prints a copy-pasteable skeleton populated with the running machine's values.

The metadata file IS tracked in git (unlike `user_credentials.json`). It's part of the host's identity.

### Phase 4 — Generate `user_credentials.json`

Use [`archinstall/user_credentials.example.json`](../../../archinstall/user_credentials.example.json) as the skeleton. Generate password hashes:

```bash
mkpasswd -m yescrypt   # for root_enc_password and users[*].enc_password
```

`!encryption-password` is a plain LUKS passphrase. Treat as max-sensitive — losing it loses the disk.

The file MUST be gitignored (already covered by `archinstall/*/user_credentials.json` in [`.gitignore`](../../../.gitignore)). Verify with `git check-ignore archinstall/<hostname>/user_credentials.json`.

For testing only, you may write a throwaway credentials file with a known passphrase (e.g. `test-luks-passphrase`) — but DO NOT reuse that passphrase on a real install.

### Phase 5 — Wire post-install hooks

Two patterns. Pick one:

#### Pattern A — recommended for new hosts: `curl | bash` to `post-install.sh`

In `user_configuration.json`:

```json
"custom_commands": [
  "curl -fsSL https://raw.githubusercontent.com/hyperlapse122/dotfiles/main/archinstall/post-install.sh | bash -s -- <username>"
]
```

`<username>` MUST match `users[*].username` in `user_credentials.json`. The script clones this repo and runs `install.sh`.

#### Pattern B — UX5606 style: inline heredoc

If the host needs custom service installation BEFORE the dotfiles bootstrap (e.g. UX5606's first-boot Secure Boot service), embed a `bash <<'TAG' ... TAG` heredoc in `custom_commands`. See `archinstall/UX5606/user_configuration.json` line 17 for the exemplar.

The heredoc runs in `arch-chroot` of the new system as root, after package install and before unmount. It can:
- Enable systemd services (`systemctl --root=/ enable foo`)
- Write `/etc/sudoers.d/`, `/etc/X11/xorg.conf.d/`, `/etc/sddm.conf.d/` files via `install -Dm644 /dev/stdin`
- Create btrfs subvolumes / swapfiles
- `chsh` for the target user
- Install `uv` for the user via `runuser -l <user> -c '...'`
- Clone this repo and run `install.sh` as the user
- Install host-specific first-boot services to `/usr/local/sbin` and `/etc/systemd/system/`

#### Optional: first-boot Secure Boot + TPM enrollment service

If the host has TPM2 + Secure Boot + LUKS, add a host-specific systemd oneshot service modeled on `archinstall/UX5606/secureboot-tpm-enroll.sh` and `ux5606-secureboot-tpm-enroll.service`. The service:

1. Runs only when firmware is in Setup Mode (sbctl can enroll keys then)
2. `sbctl create-keys && sbctl enroll-keys -m`
3. Signs systemd-boot, BOOTX64.EFI, and `/boot/EFI/Linux/*.efi` (UKIs)
4. Enrolls TPM2 LUKS unlock bound to PCR 7 via `systemd-cryptenroll`
5. Records completion in `/var/lib/<hostname>-install/secureboot-tpm.done` so it doesn't re-run

Service file MUST use `ConditionPathExists=!/var/lib/<hostname>-install/secureboot-tpm.done` for idempotency.

See [`references/secureboot-tpm-luks.md`](references/secureboot-tpm-luks.md) for the canonical sbctl + cryptenroll workflow with PCR rationale.

### Phase 6 — Burnable QEMU validation (NON-NEGOTIABLE)

Two modes — **prefer `--drive` for full automation**:

```bash
# fully-automated: provision + drive archinstall + reboot + verify in one shot
archinstall/test-host.sh <hostname> --drive

# manual: provision only, you drive the install via tmux
archinstall/test-host.sh <hostname>

# boot an already-installed qcow2 from an existing state dir (no ISO/direct kernel)
archinstall/test-host.sh --boot-installed <hostname>

# DMI auto-detect (no hostname → matches archinstall/*/host-metadata.json against
# /sys/class/dmi/id/* — succeeds iff exactly one host matches):
archinstall/test-host.sh
archinstall/test-host.sh --drive          # auto-detect + auto-drive

# print the auto-detected hostname only (scriptable):
archinstall/test-host.sh --detect
```

This:

1. Allocates `~/.cache/archinstall-host/state/<hostname>-<timestamp>/` (burnable).
2. Detects `edk2-ovmf` paths (Arch / Debian / Fedora / NixOS).
3. Copies `OVMF_VARS` into state dir (writable, blank → firmware enters Setup Mode).
4. Provisions a fresh `qcow2` disk + `swtpm` TPM 2.0.
5. Locates the Arch ISO (`--iso`, cached, or downloads from KR mirrors).
6. **Direct kernel boot**: extracts `vmlinuz-linux` + `initramfs-linux.img` from ISO, boots with `console=ttyS0,115200` — bypasses GRUB so serial console is live immediately. (Fall back: `--no-direct-boot`.)
7. Mounts `archinstall/<hostname>/` at `/mnt/host` (RO) and the state dir at `/mnt/state` (RW) via virtio-9p. **New knowledge from t14-gen2 validation:** once archinstall mounts the target root on `/mnt`, those 9p mounts are buried. Use them before `archinstall` starts; after that, recovery needs pasted files, a different mount location before chroot, or committed remote files.
8. **Generates a test-only `disk_config`** at `state_dir/test-disk-config.json` — LUKS+btrfs on `/dev/nvme0n1`, sized from `--disk` (default 40 GiB → 1 GiB EFI + 38 GiB encrypted root with `@`/`@home`/`@log`/`@snapshots` subvols).
9. Starts QEMU in q35 + SMM-on + Secure-Boot-capable mode, serial → tmux pane.

#### Manual drive

```bash
tmux attach -t archinstall-host-<hostname>
# the live ISO autologin only fires on tty1, NOT ttyS0 — log in manually:
root[ENTER]            # empty password on Arch live ISO

mount -t 9p -o trans=virtio,version=9p2000.L,ro host0 /mnt/host
mount -t 9p -o trans=virtio,version=9p2000.L     state0 /mnt/state
jq -s '.[0] * .[1]' /mnt/host/user_configuration.json /mnt/state/test-disk-config.json \
  > /mnt/state/merged-config.json
archinstall --config /mnt/state/merged-config.json --creds /mnt/host/user_credentials.json --silent
reboot
```

#### `--drive` (auto)

The harness drives the manual sequence above via `tmux send-keys`, polling the pane for known prompts. After provisioning it:

1. Waits for `archiso login:`, sends `root\n`.
2. Mounts both 9p shares.
3. Merges `user_configuration.json` with `test-disk-config.json` via `jq`.
4. Runs `archinstall --silent` with `set -o pipefail` (so a tee'd pipe doesn't mask non-zero exits).
5. Watches for `__AI_RC=<digit>` sentinel — pass/fail decided by exit code. Never match a literal `echo $?` command; require a digit to avoid false positives from terminal echo.
6. Powers off the live ISO and relaunches QEMU using the same qcow2 + OVMF VARS + TPM state, but without `-kernel`/`-initrd` and without the ISO. Direct-kernel boot is only for the installer; installed-system verification must boot through UEFI/systemd-boot.
7. Waits for the LUKS prompt.
8. Sends the `!encryption-password` from `user_credentials.json`.
9. Confirms the installed-system login prompt.

`--drive-timeout S` (default 1800) bounds how long the install can run before the harness gives up.

If `custom_commands` clone this repo and then install host-specific scripts/services from that clone, all referenced files MUST be committed and reachable from the cloned branch. The VM clone does not see local-only files. The t14-gen2 test validated the full install path through pacstrap, UKI generation, and 342-package custom install, then failed at the final service install because the service existed locally but not in the GitHub clone. Treat this as a real production-flow failure: commit/push first, or explicitly document a manual recovery.

Mirror lists are part of validation, not cosmetic config. A stale mirror can fail after most packages are already downloaded (example from `t14-gen2`: `sqlite` 404 on stale mirrors; NetworkManager pacstrap failed on `Operation too slow`; mixed mirrors caused package/signature mismatch for `libnotify`). Before a full `--drive` run, probe a current package and its `.sig` on every mirror you plan to include and remove mirrors that 404 or stall. For burnable validation, prefer a single known-synced HTTPS mirror over every mirror in a country region.

If `custom_commands` run this repo's `install.sh` as the target user, install an explicit per-user sudoers rule before that call:

```bash
install -Dm440 /dev/stdin /etc/sudoers.d/01-${USERNAME}-nopasswd <<<"${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL"
```

Do not rely only on `%wheel`; a non-interactive chroot run can still prompt for sudo during root-owned config installation and fail after the full package install.

Installed-system boot notes:

- UEFI/systemd-boot menus may render over the serial pane, but serial stdin does not always activate the selected entry. The harness launches installed boots with a USB keyboard device so QEMU monitor `sendkey` has a keyboard target.
- For fully unattended serial validation, prefer configuring installed kernel command line / loader timeout during install (`console=ttyS0,115200`, short/zero timeout), then regenerate the UKI. Without serial kernel args, the installed system may boot but not print the LUKS prompt on the tmux serial pane.

#### Verify after reboot

```bash
bootctl status                      # Secure Boot: enabled (after first-boot service runs)
sbctl status                        # Setup Mode: Disabled / Secure Boot: Enabled
systemd-cryptenroll --tpm2-device=list
cryptsetup luksDump /dev/<root-luks-device> | grep tpm2
journalctl -u <hostname>-secureboot-tpm-enroll.service
```

#### Cleanup

```bash
archinstall/test-host.sh --cleanup <hostname>   # tears down tmux + swtpm + state dir
```

If anything fails: do NOT silently fix and re-test. Document the failure, fix it in the host config or scripts, then re-run from scratch with a fresh state dir.

#### Hard requirements

`qemu-full` (or `qemu-base + qemu-system-x86`), `edk2-ovmf`, `swtpm`, `tmux`, `curl`, `jq`, `libarchive` (`bsdtar`, used to extract kernel+initrd from ISO for direct boot). KVM strongly recommended (`--no-kvm` for TCG fallback).

NixOS shorthand:

```bash
nix shell nixpkgs#libarchive nixpkgs#jq nixpkgs#swtpm \
  --command archinstall/test-host.sh <hostname> --drive
```

## Reproducible-steps checklist

Mark each box for the host before declaring done:

- [ ] `archinstall/<hostname>/user_configuration.json` exists and starts with the current `version` field
- [ ] `archinstall/<hostname>/host-metadata.json` exists and `archinstall/test-host.sh --detect` returns the hostname when run on the target machine (skip if the target is unreachable from the agent)
- [ ] `archinstall/<hostname>/user_credentials.json` exists locally and is gitignored
- [ ] CPU microcode package is in `packages` (`intel-ucode` or `amd-ucode`)
- [ ] GPU driver is in `profile_config.gfx_driver` and any extra packages are in `packages` (e.g. `sof-firmware` for T14 Gen 2)
- [ ] `bootloader_config.bootloader` matches the verification expectation (`Systemd-boot` for sbctl)
- [ ] `disk_config` has full encryption configured (or user explicitly opted out)
- [ ] `network_config.type` matches what the host actually uses
- [ ] If laptop: `app_config.power_management_config` is set
- [ ] If TPM2 + Secure Boot host: first-boot enrollment service installed via `custom_commands`
- [ ] `custom_commands` ends with the dotfiles bootstrap (`post-install.sh` or inline equivalent)
- [ ] `archinstall/test-host.sh <hostname>` completes a full install end-to-end
- [ ] After reboot inside the test VM: `bootctl status` reports Secure Boot enabled (where applicable)
- [ ] After reboot inside the test VM: `cryptsetup luksDump` shows TPM2 token (where applicable)
- [ ] Row added to `archinstall/README.md` "Hosts" table

## Anti-patterns

| Don't | Do |
|---|---|
| Hand-edit `disk_config` partition shapes | `archinstall --dry-run` and copy |
| Commit `user_credentials.json` | Verify with `git check-ignore` |
| Skip QEMU test because "it should work" | Run `test-host.sh`. Period. |
| Reuse another host's LUKS passphrase | Generate a fresh one with `pwgen -s 32` |
| Hardcode a username inside `custom_commands` AND in `user_credentials.json` | Pick one source of truth, prefer credentials |
| Mix `additional_packages` (legacy) with `packages` | Use only `packages` + `app_config` + `profile_config` |
| Use `bootloader: "Systemd-boot"` (legacy top-level) | Use nested `bootloader_config.bootloader` |
| Trust the README in [`archlinux/archinstall`](https://github.com/archlinux/archinstall) over the source | Source on GitHub is authoritative — `args.py`, `application.py`, `bootloader.py`, etc. |
| Sign with sbctl when firmware is NOT in Setup Mode | Service must check Setup Mode and bail otherwise |
| Bind TPM2 to too few PCRs (e.g. only 0) | PCR 7 (Secure Boot state) is the canonical anchor; add 11 if using UKI |

## Worked example: T14 Gen 2 (Intel)

For the current host (`hostnamectl chassis = laptop`, `ThinkPad T14 Gen 2i`):

1. ArchWiki page: <https://wiki.archlinux.org/title/Lenovo_ThinkPad_T14/T14s_(Intel)_Gen_2>
2. Identifies: Intel i5-1145G7 (`intel-ucode`), Iris Xe `8086:9A49` (Intel open-source gfx, `mesa vulkan-intel intel-media-driver`), AX201 Wi-Fi (`linux-firmware-intel`), Intel SOF audio `8086:A0C8` (**`sof-firmware` REQUIRED**), Bluetooth `8087:0026` (`bluez bluez-utils`).
3. Suspend caveat: BIOS S0ix vs S3 — recommend S0ix to avoid trackpad-lag bug.
4. fwupd works for BIOS, NVMe, fingerprint reader (`06CB:00F9`).
5. `bootloader_config = { Systemd-boot, uki: true, removable: false }` for sbctl + measured boot.
6. `app_config.power_management_config.power_management = "power-profiles-daemon"` for laptop power.
7. Add a `t14-gen2-secureboot-tpm-enroll.service` modeled on UX5606 for first-boot Secure Boot + TPM2 enrollment.
8. Write `archinstall/t14-gen2/host-metadata.json`:
   ```json
   {
     "$schema": "host-metadata.v1",
     "hostname": "t14-gen2",
     "description": "Lenovo ThinkPad T14 Gen 2 (Intel) — T14 Gen 2 daily driver",
     "archwiki_page": "https://wiki.archlinux.org/title/Lenovo_ThinkPad_T14/T14s_(Intel)_Gen_2",
     "dmi_match": {
       "sys_vendor":      "LENOVO",
       "product_version": "ThinkPad T14*Gen 2*"
     }
   }
   ```
   Verified DMI on the actual machine reads `sys_vendor=LENOVO`, `product_name=20W1S5DL0H` (per-SKU, varies), `product_version=ThinkPad T14 Gen 2i` (stable across SKUs — match on this).
9. On the laptop itself, `archinstall/test-host.sh --detect` should now print `t14-gen2` — proves the metadata is correct.
10. Then `archinstall/test-host.sh` (no args) auto-selects this host and burns a QEMU VM. Drive install via tmux, verify, document, done.

## Reference docs in this skill

- [`references/archinstall-schema.md`](references/archinstall-schema.md) — current top-level + nested config shape, with GitHub source line citations
- [`references/archwiki-pages.md`](references/archwiki-pages.md) — canonical ArchWiki pages indexed by scenario (laptop model, GPU vendor, audio, fwupd, etc.)
- [`references/secureboot-tpm-luks.md`](references/secureboot-tpm-luks.md) — sbctl key enrollment + signing + `systemd-cryptenroll` TPM2 LUKS workflow with PCR guidance
- [`references/qemu-test-harness.md`](references/qemu-test-harness.md) — exact QEMU + OVMF + swtpm invocation, tmux orchestration, 9p config injection, cleanup

## Repo conventions you must respect

From [`AGENTS.md`](../../../AGENTS.md):

- **dotbot** is invoked only via `uvx dotbot`, never installed.
- **Per-host directory** under `archinstall/<hostname>/`. No flat configs.
- **`user_credentials.json` is gitignored.** Only `user_credentials.example.json` is tracked.
- **Single-platform exception** applies to `archinstall/inspect-hardware.sh`, `archinstall/test-host.sh`, and `archinstall/post-install.sh` — they are Linux-only and document it in their headers; no `.ps1` counterparts.
- **Documentation sync is a hard rule**: if you add a new host, update `archinstall/README.md` "Hosts" table in the same commit.
- **Never commit unless asked.**
