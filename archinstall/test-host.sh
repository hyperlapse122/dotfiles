#!/usr/bin/env bash
# archinstall/test-host.sh
#
# Burnable QEMU VM harness for testing archinstall/<hostname>/ host configs
# end-to-end with UEFI Secure Boot, LUKS, and TPM2.
#
# Drives QEMU non-interactively via tmux so an agent (or human) can attach,
# watch the serial console, and send commands. Spins up a swtpm software TPM
# 2.0, OVMF firmware in Setup Mode (so sbctl key enrollment can run inside
# the guest), a 9p mount of the host config dir at /mnt/host, and user-mode
# networking with SSH on host port 2222.
#
# Used by the `archinstall-host` skill, Phase 6 (validation).
#
# Usage:
#   archinstall/test-host.sh                        auto-detect hostname via DMI, provision + start
#   archinstall/test-host.sh <hostname>             explicit hostname, provision + start
#   archinstall/test-host.sh <hostname> --drive     provision + auto-drive archinstall to completion
#   archinstall/test-host.sh --drive-only [host]    drive an already-provisioned VM (no re-provision)
#   archinstall/test-host.sh --boot-installed [host] boot an installed qcow2 from existing state
#   archinstall/test-host.sh --detect               print DMI-auto-detected hostname (or exit 1)
#   archinstall/test-host.sh <hostname> --keep      don't auto-cleanup state on session exit
#   archinstall/test-host.sh --cleanup [hostname]   tear down a running test (auto-detects if omitted)
#   archinstall/test-host.sh --list                 list active test sessions
#   archinstall/test-host.sh --help
#
# DMI auto-detect:
#   When invoked with no <hostname>, the script reads /sys/class/dmi/id/* and
#   matches against each archinstall/<hostname>/host-metadata.json file's
#   `dmi_match` block (glob patterns). Auto-selects iff exactly one host
#   matches. When <hostname> IS provided, the script does a warn-only DMI
#   validation against that host's metadata (mismatch logs a warning, does
#   not block).
#
# host-metadata.json schema (per host, optional but recommended):
#   {
#     "$schema": "host-metadata.v1",
#     "hostname": "t14-gen2",
#     "description": "Lenovo ThinkPad T14 Gen 2 (Intel) — daily driver",
#     "archwiki_page": "https://wiki.archlinux.org/title/Lenovo_ThinkPad_T14/T14s_(Intel)_Gen_2",
#     "dmi_match": {
#       "sys_vendor":      "LENOVO",
#       "product_version": "ThinkPad T14*Gen 2*"
#     }
#   }
# Empty / missing dmi_match fields are wildcards. Glob patterns use bash
# extended glob syntax (* and ?). Prefer product_version over product_name
# for laptop matches — Lenovo product_name is per-SKU (e.g. 20W1S5DL0H,
# 20XK000FKR), but product_version is the human model string and is stable
# across SKUs of the same model.
#
# Optional flags:
#   --iso PATH        use a specific Arch ISO instead of cached/auto-download
#   --disk SIZE       qcow2 size, default 40G (e.g. 60G, 80G)
#   --ram SIZE        guest RAM, default 4G
#   --smp N           guest vCPUs, default 4
#   --no-kvm          force TCG (slow; only when KVM unavailable)
#   --ssh-port N      host port forwarded to guest :22, default 2222
#   --no-direct-boot  use ISO+GRUB (legacy; serial console requires manual menu pick)
#   --drive           after provisioning, auto-drive archinstall to completion
#   --drive-timeout S max seconds to wait for archinstall to finish (default 1800)
#
# Environment:
#   ARCHINSTALL_HOST_CACHE   override cache root (default ~/.cache/archinstall-host)
#
# Single-platform (Linux) by design — see AGENTS.md script-parity exception.
# Hard requirements: qemu-system-x86_64, qemu-img, swtpm, swtpm_setup, tmux,
# OVMF firmware files, curl, jq, and bsdtar for direct kernel boot.
# KVM is strongly recommended; -enable-kvm needs /dev/kvm access.

set -euo pipefail

# ----- repo + cache layout ---------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_ROOT="${ARCHINSTALL_HOST_CACHE:-$HOME/.cache/archinstall-host}"
ISO_DIR="$CACHE_ROOT/iso"
SESSIONS_DIR="$CACHE_ROOT/sessions"

mkdir -p "$ISO_DIR" "$SESSIONS_DIR"

# ----- logging ---------------------------------------------------------------

log() { printf 'test-host: %s\n' "$*"; }
warn() { printf 'test-host: WARN: %s\n' "$*" >&2; }
die() { printf 'test-host: ERROR: %s\n' "$*" >&2; exit 1; }

# ----- arg parsing -----------------------------------------------------------

usage() {
  sed -n '4,62p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

ACTION="provision"
HOSTNAME=""
ISO=""
DISK_SIZE="40G"
RAM="4G"
SMP="4"
SSH_PORT="2222"
KVM_ARGS=(-enable-kvm)   # cleared to () by --no-kvm and the /dev/kvm probe
KEEP_STATE=0
DIRECT_BOOT=1            # 1 = -kernel/-initrd; 0 = legacy -cdrom + GRUB
AUTO_DRIVE=0             # 1 = after provision, auto-drive archinstall
DRIVE_TIMEOUT=1800       # seconds — archinstall guest install ceiling

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup)        ACTION="cleanup"; shift; HOSTNAME="${1:-}"; [[ -n "$HOSTNAME" ]] && shift || true ;;
    --detect)         ACTION="detect"; shift ;;
    --list)           ACTION="list"; shift ;;
    --keep)           KEEP_STATE=1; shift ;;
    --iso)            ISO="${2:?missing PATH for --iso}"; shift 2 ;;
    --disk)           DISK_SIZE="${2:?missing SIZE for --disk}"; shift 2 ;;
    --ram)            RAM="${2:?missing SIZE for --ram}"; shift 2 ;;
    --smp)            SMP="${2:?missing N for --smp}"; shift 2 ;;
    --ssh-port)       SSH_PORT="${2:?missing N for --ssh-port}"; shift 2 ;;
    --no-kvm)         KVM_ARGS=(); shift ;;
    --no-direct-boot) DIRECT_BOOT=0; shift ;;
    --drive)          AUTO_DRIVE=1; shift ;;
    --drive-only)     ACTION="drive-only"; shift; HOSTNAME="${1:-}"; [[ -n "$HOSTNAME" ]] && shift || true ;;
    --boot-installed) ACTION="boot-installed"; shift; HOSTNAME="${1:-}"; [[ -n "$HOSTNAME" ]] && shift || true ;;
    --drive-timeout)  DRIVE_TIMEOUT="${2:?missing N for --drive-timeout}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    -*)               die "unknown flag: $1 (try --help)" ;;
    *)
      if [[ -z "$HOSTNAME" ]]; then HOSTNAME="$1"; shift
      else die "unexpected positional arg: $1"; fi
      ;;
  esac
done

# ----- subcommand dispatch ---------------------------------------------------

session_meta_path() { printf '%s/%s.env\n' "$SESSIONS_DIR" "$1"; }

latest_state_dir() {
  local latest="" state
  shopt -s nullglob
  for state in "$CACHE_ROOT/state/$1"-*; do
    [[ -d "$state" ]] || continue
    latest="$state"
  done
  shopt -u nullglob
  [[ -n "$latest" ]] || return 1
  printf '%s\n' "$latest"
}

cmd_list() {
  shopt -s nullglob
  local found=0
  for meta in "$SESSIONS_DIR"/*.env; do
    found=1
    local h
    h="$(basename "$meta" .env)"
    printf '%-30s  %s\n' "$h" "$meta"
  done
  shopt -u nullglob
  if [[ $found -eq 0 ]]; then
    log 'no active test sessions'
  fi
}

cmd_cleanup() {
  if [[ -z "$HOSTNAME" ]]; then
    if HOSTNAME="$(auto_detect_hostname 2>/dev/null)"; then
      log "auto-detected host for cleanup: $HOSTNAME"
    else
      die '--cleanup needs a <hostname> (DMI auto-detect found no match)'
    fi
  fi
  local meta; meta="$(session_meta_path "$HOSTNAME")"
  [[ -f "$meta" ]] || die "no session metadata at $meta (already cleaned up?)"

  # Initialize sourced vars so shellcheck doesn't flag them and so unset vars
  # become empty strings instead of undefined under `set -u`.
  STATE_DIR="" TMUX_SESSION="" SWTPM_PID=""
  # shellcheck disable=SC1090
  source "$meta"

  log "killing tmux session $TMUX_SESSION (if alive)"
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

  if [[ -n "${SWTPM_PID:-}" ]] && kill -0 "$SWTPM_PID" 2>/dev/null; then
    log "killing swtpm pid $SWTPM_PID"
    kill "$SWTPM_PID" 2>/dev/null || true
  fi

  if [[ "${KEEP_STATE:-0}" -eq 1 ]]; then
    log "--keep set: leaving state dir at $STATE_DIR"
  elif [[ -n "${STATE_DIR:-}" && -d "$STATE_DIR" ]]; then
    log "removing state dir $STATE_DIR"
    rm -rf "$STATE_DIR"
  fi

  rm -f "$meta"
  log 'cleanup complete'
}

# ----- provision-time checks -------------------------------------------------

require_tools() {
  local missing=()
  local needed=(qemu-system-x86_64 qemu-img swtpm swtpm_setup tmux curl jq)
  if [[ "$DIRECT_BOOT" -eq 1 ]]; then
    needed+=(bsdtar)
  fi
  for t in "${needed[@]}"; do
    have "$t" || missing+=("$t")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    if have nix; then
      die "missing required tools: ${missing[*]}. On NixOS, wrap the call: nix shell nixpkgs#swtpm nixpkgs#qemu_full nixpkgs#libarchive nixpkgs#jq --command archinstall/test-host.sh $HOSTNAME"
    fi
    die "missing required tools: ${missing[*]}. On Arch: pacman -S qemu-full edk2-ovmf swtpm tmux curl jq libarchive"
  fi
  if [[ ${#KVM_ARGS[@]} -gt 0 && ! -r /dev/kvm ]]; then
    warn "/dev/kvm not accessible — falling back to TCG (very slow). Pass --no-kvm to silence this warning."
    KVM_ARGS=()
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# ----- DMI auto-detect + validation ------------------------------------------

# read_dmi <field>  →  prints /sys/class/dmi/id/<field>, or empty on miss.
# Uses /sys (no root needed for sys_vendor/product_name/product_version/etc)
# instead of dmidecode (root-only) for portability.
read_dmi() {
  local f="/sys/class/dmi/id/$1"
  [[ -r "$f" ]] && tr -d '\n' < "$f" || true
}

# glob_match <pattern> <value>  →  exit 0 if value glob-matches pattern.
# Empty pattern is a wildcard (always matches).
glob_match() {
  local pat="$1" val="$2"
  [[ -z "$pat" ]] && return 0
  # shellcheck disable=SC2053
  [[ "$val" == $pat ]]
}

# match_host_metadata <metadata.json>  →  exit 0 if current /sys/class/dmi/id
# values match the metadata's .dmi_match block. Missing fields are wildcards.
# Returns 1 (not 0) when jq is missing — auto-detect silently fails.
match_host_metadata() {
  local meta="$1"
  [[ -r "$meta" ]] || return 1
  have jq || return 1
  local got want
  for field in sys_vendor product_name product_version chassis_type bios_vendor; do
    want="$(jq -r ".dmi_match.${field} // empty" "$meta" 2>/dev/null)"
    [[ -z "$want" ]] && continue
    got="$(read_dmi "$field")"
    glob_match "$want" "$got" || return 1
  done
  return 0
}

# auto_detect_hostname  →  prints unique matching hostname, exit 0.
# Exit 1 when zero hosts match. Exit 2 when 2+ hosts match (prints names).
auto_detect_hostname() {
  if ! have jq; then
    warn 'jq not installed; cannot auto-detect host. install with: pacman -S jq'
    return 1
  fi
  local matches=()
  shopt -s nullglob
  local meta
  for meta in "$REPO_ROOT"/archinstall/*/host-metadata.json; do
    if match_host_metadata "$meta"; then
      matches+=("$(basename "$(dirname "$meta")")")
    fi
  done
  shopt -u nullglob

  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s\n' "${matches[0]}"
    return 0
  elif [[ ${#matches[@]} -eq 0 ]]; then
    return 1
  else
    printf 'multiple hosts match this hardware:\n' >&2
    printf '  - %s\n' "${matches[@]}" >&2
    return 2
  fi
}

# validate_host_match <hostname>  →  warn-only DMI check against the user-
# supplied hostname's metadata. No-op when metadata or jq is absent.
validate_host_match() {
  local h="$1"
  local meta="$REPO_ROOT/archinstall/$h/host-metadata.json"
  [[ -r "$meta" ]] || return 0
  if ! have jq; then
    warn "jq not installed; skipping DMI validation for host $h"
    return 0
  fi
  if match_host_metadata "$meta"; then
    log "DMI fingerprint matches host $h"
  else
    warn "DMI fingerprint MISMATCH for host $h"
    warn "  current sys_vendor      = $(read_dmi sys_vendor)"
    warn "  current product_name    = $(read_dmi product_name)"
    warn "  current product_version = $(read_dmi product_version)"
    warn "  host expects:           = $(jq -c .dmi_match "$meta")"
    warn 'continuing anyway — pass a different hostname if this is wrong'
  fi
}

# Warn early when the host config's custom_commands clone this Git repo and then
# install host-specific files from that clone. A VM sees the public/default
# branch clone, NOT local uncommitted files in this worktree. The t14-gen2
# test caught this the hard way: archinstall succeeded, packages installed, UKI
# was generated, then custom_commands failed because the first-boot service files
# existed locally but not in the cloned repo.
warn_if_custom_commands_reference_local_only_files() {
  local h="$1"
  local host_dir="$REPO_ROOT/archinstall/$h"
  local config="$host_dir/user_configuration.json"
  [[ -r "$config" ]] || return 0
  have git || return 0
  have jq || return 0

  if ! jq -er --arg host "$h" '.custom_commands[]? | select(contains("$DOTFILES_DIR/archinstall/" + $host + "/"))' "$config" >/dev/null; then
    return 0
  fi

  local dirty=0 file rel
  shopt -s nullglob
  for file in "$host_dir"/*.sh "$host_dir"/*.service; do
    rel="${file#"$REPO_ROOT"/}"
    if ! git -C "$REPO_ROOT" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
      warn "custom_commands clone this repo, but $rel is not tracked; the VM clone will not contain it"
      dirty=1
    elif ! git -C "$REPO_ROOT" diff --quiet -- "$rel"; then
      warn "custom_commands clone this repo, but $rel has uncommitted changes; the VM clone will not contain them"
      dirty=1
    fi
  done
  shopt -u nullglob

  if [[ "$dirty" -eq 1 ]]; then
    warn 'push/commit the referenced host files before a production-faithful --drive run, or recover manually from the live ISO.'
  fi
}

cmd_detect() {
  local h
  if h="$(auto_detect_hostname)"; then
    printf '%s\n' "$h"
  else
    local rc=$?
    if [[ $rc -eq 1 ]]; then
      die 'no host matches the current DMI fingerprint. create archinstall/<hostname>/host-metadata.json or pass <hostname> explicitly to test-host.sh.'
    else
      exit $rc   # 2 = ambiguous, already printed names to stderr
    fi
  fi
}

# Discover OVMF firmware paths across distros. Sets OVMF_CODE and OVMF_VARS_TPL.
discover_ovmf() {
  local code_candidates=(
    # Arch
    /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd
    # Older Arch
    /usr/share/edk2-ovmf/x64/OVMF_CODE.secboot.fd
    # Debian/Ubuntu (ovmf package)
    /usr/share/OVMF/OVMF_CODE.secboot.fd
    # Fedora (edk2-ovmf package)
    /usr/share/OVMF/x64/OVMF_CODE.secboot.4m.fd
    # NixOS — libvirt nix-ovmf compatibility staging (qemu-provided edk2)
    /run/libvirt/nix-ovmf/edk2-x86_64-secure-code.fd
    # NixOS — system-wide qemu share
    /run/current-system/sw/share/qemu/edk2-x86_64-secure-code.fd
    # openSUSE
    /usr/share/qemu/ovmf-x86_64-smm-ms-code.bin
  )
  local vars_candidates=(
    # Arch
    /usr/share/edk2/x64/OVMF_VARS.4m.fd
    # Older Arch
    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd
    # Debian/Ubuntu
    /usr/share/OVMF/OVMF_VARS.fd
    # Fedora
    /usr/share/OVMF/x64/OVMF_VARS.4m.fd
    # NixOS — edk2 ships one shared vars template (i386 path is canonical, used by x86_64 too)
    /run/libvirt/nix-ovmf/edk2-i386-vars.fd
    /run/current-system/sw/share/qemu/edk2-i386-vars.fd
    # openSUSE
    /usr/share/qemu/ovmf-x86_64-smm-ms-vars.bin
  )

  OVMF_CODE=""
  for c in "${code_candidates[@]}"; do
    if [[ -r "$c" ]]; then OVMF_CODE="$c"; break; fi
  done
  OVMF_VARS_TPL=""
  for v in "${vars_candidates[@]}"; do
    if [[ -r "$v" ]]; then OVMF_VARS_TPL="$v"; break; fi
  done

  [[ -n "$OVMF_CODE" ]] || die 'OVMF Secure Boot CODE firmware not found. Install edk2-ovmf (Arch) / ovmf (Debian/Fedora).'
  [[ -n "$OVMF_VARS_TPL" ]] || die 'OVMF VARS template not found. Install edk2-ovmf / ovmf.'
  log "OVMF CODE:        $OVMF_CODE"
  log "OVMF VARS (tmpl): $OVMF_VARS_TPL"
}

# Locate or download a recent Arch ISO. Sets ISO if unset.
#
# Mirror selection order:
#   1. --iso PATH               explicit
#   2. cached file in $ISO_DIR  newest archlinux-*.iso
#   3. $ARCHINSTALL_HOST_ISO_MIRROR     env override (single base URL, no trailing slash)
#   4. KR_ISO_MIRRORS array     South Korea mirrors (matches the repo's mirror_config defaults)
#   5. geo.mirror.pkgbuild.com  global fallback
locate_iso() {
  if [[ -n "$ISO" ]]; then
    [[ -r "$ISO" ]] || die "explicit --iso path is unreadable: $ISO"
    log "using ISO: $ISO"
    return
  fi

  shopt -s nullglob
  local cached=("$ISO_DIR"/archlinux-*.iso)
  shopt -u nullglob
  if [[ ${#cached[@]} -gt 0 ]]; then
    # Use the newest cached ISO. Filenames are controlled (archlinux-*.iso),
    # no weird chars to defeat ls.
    # shellcheck disable=SC2012
    ISO="$(ls -t "${cached[@]}" | head -1)"
    log "using cached ISO: $ISO"
    return
  fi

  log 'no cached Arch ISO found; downloading...'
  log 'tip: pre-download to '"$ISO_DIR"' and pass --iso PATH to skip this.'

  local stem="archlinux-x86_64.iso"
  local dest="$ISO_DIR/$stem"

  # Build an ordered candidate list. KR mirrors first (matches the repo's
  # mirror_config defaults — UX5606 + t14-gen2 both use South Korea
  # package mirrors). geo.mirror.pkgbuild.com last as the global fallback.
  local mirror_candidates=()
  if [[ -n "${ARCHINSTALL_HOST_ISO_MIRROR:-}" ]]; then
    mirror_candidates+=("${ARCHINSTALL_HOST_ISO_MIRROR%/}")
  fi
  mirror_candidates+=(
    https://ftp.kaist.ac.kr/ArchLinux/iso/latest
    https://mirror.siwoo.org/archlinux/iso/latest
    https://mirror.funami.tech/arch/iso/latest
    https://mirror.keiminem.com/archlinux/iso/latest
    https://ftp.lanet.kr/pub/archlinux/iso/latest
    https://mirror.distly.kr/archlinux/iso/latest
    https://geo.mirror.pkgbuild.com/iso/latest
  )

  local mirror url
  for mirror in "${mirror_candidates[@]}"; do
    url="$mirror/$stem"
    log "trying mirror: $mirror"
    if curl -fL --connect-timeout 10 --output "$dest.partial" "$url"; then
      mv "$dest.partial" "$dest"
      ISO="$dest"
      log "downloaded ISO from $mirror"
      return
    fi
    rm -f "$dest.partial"
    warn "  $mirror failed; trying next"
  done
  die 'all ISO mirrors failed'
}

# ----- direct kernel boot ----------------------------------------------------

# Extract vmlinuz-linux + initramfs-linux.img from the Arch ISO into $1 (state
# dir), and detect the ISO volume label. Sets ARCHISO_LABEL globally.
#
# This bypasses GRUB entirely so we don't have to race the boot menu timer to
# pick a serial-console entry. We pass `console=ttyS0,115200` directly on the
# kernel cmdline, which is the same thing the ISO's "Serial Console" GRUB entry
# would have done.
#
# bsdtar can read ISO9660 directly without mounting (no root). The ISO label
# ("ARCH_YYYYMM") is needed for the archiso initramfs hooks to find the
# squashfs at boot.
prepare_kernel_initrd() {
  local out_dir="$1"

  log 'extracting vmlinuz + initramfs from ISO (direct kernel boot)'
  bsdtar -xf "$ISO" -C "$out_dir" \
    arch/boot/x86_64/vmlinuz-linux \
    arch/boot/x86_64/initramfs-linux.img

  [[ -f "$out_dir/arch/boot/x86_64/vmlinuz-linux" ]] \
    || die "failed to extract vmlinuz-linux from $ISO"
  [[ -f "$out_dir/arch/boot/x86_64/initramfs-linux.img" ]] \
    || die "failed to extract initramfs-linux.img from $ISO"

  # ISO 9660 volume label: bsdtar exposes it via the iso9660 inspector but the
  # cleanest cross-distro method is to read the volume descriptor directly.
  # The label sits at byte offset 0x8028, ASCII, 32 bytes, space-padded.
  ARCHISO_LABEL="$(dd if="$ISO" bs=1 count=32 skip=32808 status=none 2>/dev/null \
    | tr -d '\0' | sed 's/[[:space:]]*$//')"
  if [[ -z "$ARCHISO_LABEL" ]]; then
    die 'could not read ISO volume label (needed for archisolabel kernel param)'
  fi
  log "ISO volume label: $ARCHISO_LABEL"
}

# Writes a test-only disk_config.json template into $1 (state dir). Layout:
#
#   /dev/nvme0n1p1   1   GiB  FAT32 ESP   → /efi   (Boot,ESP flags)
#   /dev/nvme0n1p2   rest GiB  LUKS2/btrfs → /, /home, /var/log, /.snapshots
#
# disk_encryption.encryption_password is intentionally omitted — archinstall
# reads it from user_credentials.json's `!encryption-password` field. Same
# obj_id is referenced from both the partitions array and
# disk_encryption.partitions[].
#
# Schema notes (archinstall v3.0.x, master @ 2026):
#   * Every Size/Start MUST embed a SectorSize object (not null). archinstall
#     calls Size.parse_args(arg) which does `Unit[arg['unit']]` and
#     `SectorSize.parse_args(arg['sector_size'])['value']`. NVMe-on-QEMU
#     defaults to 512 B sectors.
#   * Unit enum has NO `Percent` — only B/KiB/MiB/GiB/TiB and decimal
#     equivalents. "Use the rest of the disk" must be expressed as an
#     explicit GiB length, computed from $DISK_SIZE here.
#   * Every partition needs `dev_path` (null for create-status partitions).
#   * disk_encryption.partitions[] takes obj_id strings, NOT full objects.
write_test_disk_config() {
  local out_dir="$1"
  local efi_id="11111111-1111-4111-8111-111111111111"
  local root_id="22222222-2222-4222-8222-222222222222"
  local sector='{"unit":"B","value":512}'

  # qemu-img treats "40G" as 40 GiB (binary). Reserve 1 GiB for the EFI
  # partition + 1 GiB safety slack at the end of the disk so the GPT backup
  # header has room and we don't trip archinstall's alignment / overlap check.
  local disk_gib root_gib root_start_mib
  disk_gib="$(printf '%s' "$DISK_SIZE" | sed -E 's/[Gg][Ii]?[Bb]?$//')"
  if [[ ! "$disk_gib" =~ ^[0-9]+$ ]] || [[ "$disk_gib" -lt 8 ]]; then
    die "DISK_SIZE must be e.g. 40G / 60G with disk_gib >= 8 (got: $DISK_SIZE)"
  fi
  root_gib=$((disk_gib - 2))     # 1 GiB EFI + 1 GiB tail slack
  root_start_mib=1025            # next 1-MiB alignment after 1 GiB EFI ends

  cat > "$out_dir/test-disk-config.json" <<TEST_DISK_CONFIG
{
  "disk_config": {
    "config_type": "manual_partitioning",
    "device_modifications": [
      {
        "device": "/dev/nvme0n1",
        "wipe": true,
        "partitions": [
          {
            "btrfs": [],
            "dev_path": null,
            "flags": ["Boot", "ESP"],
            "fs_type": "fat32",
            "mount_options": [],
            "mountpoint": "/efi",
            "obj_id": "$efi_id",
            "size":  { "sector_size": $sector, "unit": "GiB", "value": 1 },
            "start": { "sector_size": $sector, "unit": "MiB", "value": 1 },
            "status": "create",
            "type": "primary"
          },
          {
            "btrfs": [
              { "name": "@",          "mountpoint": "/" },
              { "name": "@home",      "mountpoint": "/home" },
              { "name": "@log",       "mountpoint": "/var/log" },
              { "name": "@snapshots", "mountpoint": "/.snapshots" }
            ],
            "dev_path": null,
            "flags": [],
            "fs_type": "btrfs",
            "mount_options": ["compress=zstd"],
            "mountpoint": null,
            "obj_id": "$root_id",
            "size":  { "sector_size": $sector, "unit": "GiB", "value": $root_gib },
            "start": { "sector_size": $sector, "unit": "MiB", "value": $root_start_mib },
            "status": "create",
            "type": "primary"
          }
        ]
      }
    ],
    "disk_encryption": {
      "encryption_type": "luks",
      "partitions": ["$root_id"],
      "lvm_volumes": [],
      "iter_time": 10000
    }
  }
}
TEST_DISK_CONFIG
  log "wrote test disk_config (disk=${disk_gib} GiB, root=${root_gib} GiB): $out_dir/test-disk-config.json"
}

# ----- provision -------------------------------------------------------------

cmd_provision() {
  if [[ -z "$HOSTNAME" ]]; then
    log 'no hostname given; trying DMI auto-detect against archinstall/*/host-metadata.json...'
    local rc=0
    HOSTNAME="$(auto_detect_hostname)" || rc=$?
    if [[ $rc -ne 0 ]]; then
      if [[ $rc -eq 2 ]]; then
        die 'multiple hosts match this hardware (see above) — pass <hostname> explicitly'
      fi
      die "no host config matches this machine's DMI fingerprint. pass <hostname> explicitly, or add archinstall/<hostname>/host-metadata.json. (current: sys_vendor=$(read_dmi sys_vendor) product_name=$(read_dmi product_name) product_version=$(read_dmi product_version))"
    fi
    log "auto-detected host: $HOSTNAME"
  else
    validate_host_match "$HOSTNAME"
  fi

  local host_dir="$REPO_ROOT/archinstall/$HOSTNAME"
  [[ -d "$host_dir" ]] || die "no host config at $host_dir"
  [[ -f "$host_dir/user_configuration.json" ]] \
    || die "missing $host_dir/user_configuration.json (run archinstall --dry-run first)"

  if [[ ! -f "$host_dir/user_credentials.json" ]]; then
    warn "no user_credentials.json at $host_dir — archinstall will fail in --silent mode"
    warn "create one from archinstall/user_credentials.example.json before driving the install"
  fi
  warn_if_custom_commands_reference_local_only_files "$HOSTNAME"

  require_tools
  discover_ovmf
  locate_iso

  local meta; meta="$(session_meta_path "$HOSTNAME")"
  if [[ -f "$meta" ]]; then
    die "session metadata already exists at $meta. Run: archinstall/test-host.sh --cleanup $HOSTNAME"
  fi

  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local state_dir="$CACHE_ROOT/state/$HOSTNAME-$stamp"
  mkdir -p "$state_dir/tpm"
  log "state dir:        $state_dir"

  # 1. Writable OVMF VARS copy. Blank template = firmware boots in Setup Mode,
  #    which is required so sbctl can enroll user keys from inside the guest.
  cp "$OVMF_VARS_TPL" "$state_dir/OVMF_VARS.fd"
  chmod u+w "$state_dir/OVMF_VARS.fd"

  # 1a. Direct kernel boot prep + test disk_config. Direct boot bypasses GRUB
  #     so the live ISO comes up immediately on serial console.
  if [[ "$DIRECT_BOOT" -eq 1 ]]; then
    prepare_kernel_initrd "$state_dir"
  fi
  write_test_disk_config "$state_dir"

  # 2. qcow2 disk for the install target.
  qemu-img create -q -f qcow2 "$state_dir/disk.qcow2" "$DISK_SIZE"

  # 3. Initialize swtpm state, then start it as a daemon listening on a unix
  #    socket QEMU consumes. The --create-ek-cert / --create-platform-cert
  #    flags want to write to a system-wide CA dir (/etc/swtpm-localca/) and
  #    fail on NixOS / non-Arch hosts; we skip them. Real Arch installs of
  #    swtpm pre-create the dir, so add them back if you want firmware-grade
  #    EK/platform certs and you're on a swtpm-aware distro.
  swtpm_setup --tpm2 --tpmstate "$state_dir/tpm" \
    --overwrite --pcr-banks - >/dev/null
  swtpm socket --tpm2 \
    --tpmstate "dir=$state_dir/tpm,mode=0600" \
    --ctrl "type=unixio,path=$state_dir/tpm/swtpm-sock" \
    --pid "file=$state_dir/tpm/swtpm.pid" \
    --daemon

  # Wait briefly for the socket to appear.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -S "$state_dir/tpm/swtpm-sock" ]] && break
    sleep 0.2
  done
  [[ -S "$state_dir/tpm/swtpm-sock" ]] || die 'swtpm socket never appeared'
  local swtpm_pid; swtpm_pid="$(cat "$state_dir/tpm/swtpm.pid")"
  log "swtpm pid:        $swtpm_pid"

  # 4. Build the QEMU argv. Notes:
  #    -machine q35,smm=on              SMM is required for Secure Boot
  #    -global cfi.pflash01,secure=on   marks NVRAM as SMM-protected
  #    pflash CODE = readonly, VARS = writable per-VM
  #    virtio-9p mounts the host config tree into the guest at /mnt/host (RO)
  #    second 9p mount  → guest /mnt/state                            (RW; merged config + drive logs)
  #    direct kernel boot: -kernel/-initrd bypasses GRUB so serial console works immediately
  #    -display none -serial mon:stdio  stdio = the tmux pane = agent's view
  local qemu_argv=(
    qemu-system-x86_64
    "${KVM_ARGS[@]}"
    -cpu host
    -smp "$SMP"
    -m "$RAM"
    -machine "q35,smm=on"
    -global "driver=cfi.pflash01,property=secure,value=on"
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$state_dir/OVMF_VARS.fd"
    -drive "file=$state_dir/disk.qcow2,if=none,id=hd0,format=qcow2"
    -device "nvme,drive=hd0,serial=test-host-$HOSTNAME"
    -drive "file=$ISO,if=none,id=cd0,format=raw,readonly=on,media=cdrom"
    -device "ide-cd,drive=cd0,bus=ide.0"
    -netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22"
    -device "virtio-net-pci,netdev=net0"
    -chardev "socket,id=chrtpm,path=$state_dir/tpm/swtpm-sock"
    -tpmdev "emulator,id=tpm0,chardev=chrtpm"
    -device "tpm-tis,tpmdev=tpm0"
    -virtfs "local,path=$host_dir,mount_tag=host0,security_model=none,id=host0,readonly=on"
    -virtfs "local,path=$state_dir,mount_tag=state0,security_model=none,id=state0"
    -display "none"
    -serial "mon:stdio"
    -name "archinstall-host-$HOSTNAME"
  )

  if [[ "$DIRECT_BOOT" -eq 1 ]]; then
    qemu_argv+=(
      -kernel "$state_dir/arch/boot/x86_64/vmlinuz-linux"
      -initrd "$state_dir/arch/boot/x86_64/initramfs-linux.img"
      -append "archisobasedir=arch archisolabel=$ARCHISO_LABEL console=ttyS0,115200 cow_spacesize=2G"
    )
  else
    qemu_argv+=(-boot "order=d")
  fi

  # 5. Tmux session with QEMU running. Agents attach to drive the install.
  local tmux_session="archinstall-host-$HOSTNAME"
  if tmux has-session -t "$tmux_session" 2>/dev/null; then
    die "tmux session $tmux_session already exists (cleanup first)"
  fi

  # Build the qemu cmdline as a single quoted string for tmux send-keys.
  # printf %q quotes each arg safely.
  local qemu_cmd=""
  for a in "${qemu_argv[@]}"; do qemu_cmd+="$(printf %q "$a") "; done

  tmux new-session -d -s "$tmux_session" -n qemu
  tmux send-keys -t "$tmux_session:qemu" "$qemu_cmd" Enter

  # 6. Persist session metadata so --cleanup can find everything.
  cat > "$meta" <<META
HOSTNAME=$HOSTNAME
STATE_DIR=$state_dir
TMUX_SESSION=$tmux_session
SWTPM_PID=$swtpm_pid
ISO=$ISO
OVMF_CODE=$OVMF_CODE
OVMF_VARS=$state_dir/OVMF_VARS.fd
DISK=$state_dir/disk.qcow2
SSH_PORT=$SSH_PORT
KEEP_STATE=$KEEP_STATE
DIRECT_BOOT=$DIRECT_BOOT
STARTED=$stamp
META

  # 7. Either auto-drive or print instructions for manual attach.
  if [[ "$AUTO_DRIVE" -eq 1 ]]; then
    drive_install
    return
  fi

  cat <<INSTRUCTIONS

================================================================================
Burnable QEMU VM provisioned for host: $HOSTNAME

  state dir:     $state_dir
  tmux session:  $tmux_session
  swtpm pid:     $swtpm_pid
  SSH (later):   ssh -p $SSH_PORT user@127.0.0.1

Attach to the serial console (it is the tmux pane's stdin/stdout):

  tmux attach -t $tmux_session

In the Arch ISO boot menu, pick the "Boot Arch Linux (x86_64) with serial console"
entry (or hit 'e' on the default entry and append: console=ttyS0,115200) so kernel
output reaches the serial console you're watching.

Once booted to the live shell, drive the install:

  mount -t 9p -o trans=virtio host0 /mnt/host
  archinstall \\
    --config /mnt/host/user_configuration.json \\
    --creds  /mnt/host/user_credentials.json \\
    --silent
  reboot

After reboot, verify Secure Boot + TPM2 enrollment in the installed system:

  bootctl status
  sbctl status
  systemd-cryptenroll --tpm2-device=list
  cryptsetup luksDump <LUKS_DEVICE> | grep tpm2

When done:

  archinstall/test-host.sh --cleanup $HOSTNAME
================================================================================
INSTRUCTIONS
}

# ----- auto-drive (tmux send-keys) -------------------------------------------

# Capture the QEMU pane's recent output. Use a sliding window (-pS -2000) so we
# don't miss boot messages that scrolled off-screen between polls.
pane_capture() {
  local session="$1"
  tmux capture-pane -t "$session:qemu" -pS -2000 2>/dev/null || true
}

# Wait for a regex to appear in the pane. Returns 0 on hit, 1 on timeout.
# $1=session, $2=regex, $3=description, $4=timeout-seconds (default 180).
pane_wait_for() {
  local session="$1" regex="$2" desc="$3" timeout="${4:-180}"
  log "waiting for $desc (timeout ${timeout}s)..."
  local i
  for ((i = 1; i <= timeout; i++)); do
    if pane_capture "$session" | grep -Eq -- "$regex"; then
      log "  matched after ${i}s: $desc"
      return 0
    fi
    sleep 1
  done
  warn "timed out after ${timeout}s waiting for: $desc"
  warn 'last 40 lines of pane output:'
  pane_capture "$session" | tail -40 >&2
  return 1
}

# Send a single command (newline-terminated). Pane waits 0.3s after to settle.
pane_send() {
  local session="$1" cmd="$2"
  tmux send-keys -t "$session:qemu" "$cmd" Enter
  sleep 0.3
}

drive_install() {
  local session="archinstall-host-$HOSTNAME"
  local host_dir="$REPO_ROOT/archinstall/$HOSTNAME"
  local state_dir
  state_dir="$(grep -E '^STATE_DIR=' "$(session_meta_path "$HOSTNAME")" | cut -d= -f2-)"

  log '=== auto-driving archinstall ==='
  log "session:    $session"
  log "state_dir:  $state_dir"
  log "host_dir:   $host_dir"

  # Phase 1: wait for the login prompt, then perform manual root login.
  #
  # The Arch live ISO autologins root on tty1 (the local console), but NOT on
  # ttyS0 (the serial console we're using). Direct kernel boot with
  # `console=ttyS0,115200` puts us on serial, so we must `root\n` ourselves.
  # The root account on the live ISO has an empty password, so login succeeds
  # without prompting.
  pane_wait_for "$session" 'archiso login:' 'archiso login prompt' 240 \
    || die 'archiso never reached login prompt'
  log 'logging in as root over serial console'
  pane_send "$session" 'root'
  pane_wait_for "$session" 'root@archiso ~ #' 'root shell prompt' 30 \
    || die 'root login failed (no shell prompt after sending "root")'

  # Phase 2: mount 9p filesystems. host0 = host config (RO), state0 = state dir (RW).
  log 'mounting 9p shares inside guest'
  pane_send "$session" 'mkdir -p /mnt/host /mnt/state'
  pane_send "$session" 'mount -t 9p -o trans=virtio,version=9p2000.L,ro host0 /mnt/host'
  pane_send "$session" 'mount -t 9p -o trans=virtio,version=9p2000.L     state0 /mnt/state'
  sleep 2
  pane_send "$session" 'ls /mnt/host /mnt/state'
  pane_wait_for "$session" 'user_configuration\.json' '9p mount visible' 30 \
    || die '9p mount of host config failed'

  # Phase 3: merge the host config with the test disk_config so archinstall
  # has everything it needs for --silent. archinstall 3.0.x reads the LUKS
  # passphrase from top-level `encryption_password`, while older/example creds
  # used `!encryption-password`; normalize that key into a tiny overlay. The
  # merged file lives in /mnt/state so it is visible from the host for forensics.
  log 'merging user_configuration.json + test-disk-config.json'
  pane_send "$session" \
    'jq '\''if has("!encryption-password") and (has("encryption_password") | not) then { encryption_password: .["!encryption-password"] } else { encryption_password: .encryption_password } end'\'' /mnt/host/user_credentials.json > /mnt/state/encryption-creds-overlay.json'
  pane_send "$session" \
    'jq -s ".[0] * .[1] * .[2]" /mnt/host/user_configuration.json /mnt/state/test-disk-config.json /mnt/state/encryption-creds-overlay.json > /mnt/state/merged-config.json && echo MERGED_OK'
  pane_wait_for "$session" 'MERGED_OK' 'config merge' 10 \
    || die 'jq config merge failed'
  pane_send "$session" \
    'jq -e '\''(.encryption_password | type == "string" and length > 0) and (.disk_config.disk_encryption.encryption_type == "luks")'\'' /mnt/state/merged-config.json >/dev/null && echo ENCRYPTION_CONFIG_OK'
  pane_wait_for "$session" 'ENCRYPTION_CONFIG_OK' 'encryption config validation' 10 \
    || die 'merged config is missing LUKS encryption settings'

  # Phase 4: kick off archinstall in --silent mode. Tee output to /mnt/state
  # for offline inspection. The custom_commands inside the config WILL run
  # at the end, including the dotfiles bootstrap.
  #
  # `set -o pipefail` is critical — without it, the pipe to tee always returns
  # 0 even when archinstall crashes, masking install failures as "success".
  #
  # Sentinel choice: `__AI_RC=NN` — a unique token unlikely to appear in either
  # archinstall's output or the literal command echo. The completion regex
  # requires a digit after `=` so the literal echo of `__AI_RC=$?` (which the
  # pane shows immediately as the line is typed) does not false-match.
  log 'starting archinstall --silent (this takes 10-25 min)'
  pane_send "$session" \
    'set -o pipefail; archinstall --config /mnt/state/merged-config.json --creds /mnt/host/user_credentials.json --silent 2>&1 | tee /mnt/state/archinstall.log; echo __AI_RC=$?'

  if ! pane_wait_for "$session" '__AI_RC=[0-9]+' 'archinstall to finish' "$DRIVE_TIMEOUT"; then
    die "archinstall did not finish within ${DRIVE_TIMEOUT}s — check tmux session"
  fi
  if pane_capture "$session" | grep -Eq '__AI_RC=0(\b|$)'; then
    log 'archinstall reported success'
  else
    warn 'archinstall reported a non-zero exit code'
    warn 'last 60 lines of archinstall.log:'
    [[ -f "$state_dir/archinstall.log" ]] && tail -60 "$state_dir/archinstall.log" >&2 || true
    return 1
  fi

  # Phase 5: boot into the installed system. Direct-kernel boot is ONLY for the
  # live ISO; if we simply `reboot`, QEMU will boot the same ISO kernel again.
  # Power off the live ISO, then relaunch QEMU against the same qcow2 + OVMF
  # VARS + TPM state with NO -kernel/-initrd and NO ISO so UEFI loads
  # systemd-boot from the installed ESP.
  log 'powering off live ISO before installed-disk boot'
  pane_send "$session" 'sync && poweroff -f'
  sleep 5
  boot_installed_vm

  # Phase 6: wait for the installed system. We expect the kernel to boot,
  # the LUKS prompt to appear (we have NOT enrolled TPM2 yet), and after
  # entering the passphrase, the hostname to appear in the login prompt.
  if ! pane_wait_for "$session" "Please enter passphrase|Enter passphrase for|enter passphrase for|$HOSTNAME login:" \
       'installed-system boot (LUKS prompt or login)' 300; then
    warn 'installed system never reached LUKS prompt or login'
    return 1
  fi

  if pane_capture "$session" | grep -Eq 'Please enter passphrase|Enter passphrase for|enter passphrase for'; then
    log 'LUKS prompt seen — entering passphrase'
    local passphrase
    passphrase="$(jq -r '.encryption_password // ."!encryption-password"' "$host_dir/user_credentials.json")"
    pane_send "$session" "$passphrase"
    pane_wait_for "$session" "$HOSTNAME login:" 'installed-system login prompt' 240 \
      || warn 'login prompt never appeared after LUKS unlock'
  fi

  log '=== auto-drive complete ==='
  log "see archinstall log: $state_dir/archinstall.log"
  log "to attach:           tmux attach -t $session"
  log "to clean up:         archinstall/test-host.sh --cleanup $HOSTNAME"
}

cmd_drive_only() {
  if [[ -z "$HOSTNAME" ]]; then
    if HOSTNAME="$(auto_detect_hostname 2>/dev/null)"; then
      log "auto-detected host for drive-only: $HOSTNAME"
    else
      die '--drive-only needs a <hostname> (or DMI metadata)'
    fi
  fi
  local meta; meta="$(session_meta_path "$HOSTNAME")"
  [[ -f "$meta" ]] || die "no provisioned VM at $meta — run provision first"
  drive_install
}

boot_installed_vm() {
  local meta; meta="$(session_meta_path "$HOSTNAME")"
  [[ -f "$meta" ]] || die "no session metadata at $meta — cannot boot installed disk"

  STATE_DIR="" TMUX_SESSION="" SWTPM_PID="" ISO="" OVMF_CODE="" OVMF_VARS="" DISK="" SSH_PORT="" KEEP_STATE="" DIRECT_BOOT="" STARTED=""
  # shellcheck disable=SC1090
  source "$meta"

  [[ -n "$STATE_DIR" && -d "$STATE_DIR" ]] || die "state dir missing: $STATE_DIR"
  [[ -r "$DISK" ]] || die "installed disk missing: $DISK"
  [[ -r "$OVMF_CODE" ]] || die "OVMF CODE missing: $OVMF_CODE"
  [[ -r "$OVMF_VARS" ]] || die "OVMF VARS missing: $OVMF_VARS"

  DIRECT_BOOT=0
  require_tools

  log "booting installed disk for host $HOSTNAME (no ISO, no -kernel/-initrd)"
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

  if [[ -n "${SWTPM_PID:-}" ]] && kill -0 "$SWTPM_PID" 2>/dev/null; then
    kill "$SWTPM_PID" 2>/dev/null || true
  fi
  log 'restarting swtpm against preserved TPM state'
  rm -f "$STATE_DIR/tpm/swtpm-sock" "$STATE_DIR/tpm/swtpm.pid"
  swtpm socket --tpm2 \
    --tpmstate "dir=$STATE_DIR/tpm,mode=0600" \
    --ctrl "type=unixio,path=$STATE_DIR/tpm/swtpm-sock" \
    --pid "file=$STATE_DIR/tpm/swtpm.pid" \
    --daemon
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -S "$STATE_DIR/tpm/swtpm-sock" ]] && break
    sleep 0.2
  done
  [[ -S "$STATE_DIR/tpm/swtpm-sock" ]] || die 'swtpm socket never appeared during installed boot'
  SWTPM_PID="$(cat "$STATE_DIR/tpm/swtpm.pid")"

  local qemu_argv=(
    qemu-system-x86_64
    "${KVM_ARGS[@]}"
    -cpu host
    -smp "$SMP"
    -m "$RAM"
    -machine "q35,smm=on"
    -global "driver=cfi.pflash01,property=secure,value=on"
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$OVMF_VARS"
    -drive "file=$DISK,if=none,id=hd0,format=qcow2"
    -device "nvme,drive=hd0,serial=test-host-$HOSTNAME"
    -boot "order=c"
    -netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22"
    -device "virtio-net-pci,netdev=net0"
    -chardev "socket,id=chrtpm,path=$STATE_DIR/tpm/swtpm-sock"
    -tpmdev "emulator,id=tpm0,chardev=chrtpm"
    -device "tpm-tis,tpmdev=tpm0"
    # A virtual USB keyboard gives QEMU monitor `sendkey` something firmware UI can consume.
    -device "qemu-xhci"
    -device "usb-kbd"
    -display "none"
    -serial "mon:stdio"
    -name "archinstall-host-$HOSTNAME"
  )

  local qemu_cmd="" a
  for a in "${qemu_argv[@]}"; do qemu_cmd+="$(printf %q "$a") "; done
  tmux new-session -d -s "$TMUX_SESSION" -n qemu
  tmux send-keys -t "$TMUX_SESSION:qemu" "$qemu_cmd" Enter

  cat > "$meta" <<META
HOSTNAME=$HOSTNAME
STATE_DIR=$STATE_DIR
TMUX_SESSION=$TMUX_SESSION
SWTPM_PID=$SWTPM_PID
ISO=$ISO
OVMF_CODE=$OVMF_CODE
OVMF_VARS=$OVMF_VARS
DISK=$DISK
SSH_PORT=$SSH_PORT
KEEP_STATE=$KEEP_STATE
DIRECT_BOOT=0
STARTED=$STARTED
META

  log "installed-disk boot started in tmux session $TMUX_SESSION"
}

cmd_boot_installed() {
  if [[ -z "$HOSTNAME" ]]; then
    if HOSTNAME="$(auto_detect_hostname 2>/dev/null)"; then
      log "auto-detected host for installed boot: $HOSTNAME"
    else
      die '--boot-installed needs a <hostname> (or DMI metadata)'
    fi
  fi
  local meta; meta="$(session_meta_path "$HOSTNAME")"
  if [[ ! -f "$meta" ]]; then
    local state_dir started ovmf_code
    state_dir="$(latest_state_dir "$HOSTNAME")" \
      || die "no session metadata at $meta and no kept state dir for $HOSTNAME"
    [[ -r "$state_dir/disk.qcow2" ]] || die "kept state has no disk image: $state_dir/disk.qcow2"
    [[ -r "$state_dir/OVMF_VARS.fd" ]] || die "kept state has no OVMF VARS: $state_dir/OVMF_VARS.fd"
    discover_ovmf >/dev/null
    ovmf_code="$OVMF_CODE"
    started="${state_dir##*-}"
    cat > "$meta" <<META
HOSTNAME=$HOSTNAME
STATE_DIR=$state_dir
TMUX_SESSION=archinstall-host-$HOSTNAME
SWTPM_PID=
ISO=$ISO
OVMF_CODE=$ovmf_code
OVMF_VARS=$state_dir/OVMF_VARS.fd
DISK=$state_dir/disk.qcow2
SSH_PORT=$SSH_PORT
KEEP_STATE=1
DIRECT_BOOT=0
STARTED=$started
META
    log "recovered session metadata from kept state: $state_dir"
  fi
  boot_installed_vm
}

# ----- entry -----------------------------------------------------------------

case "$ACTION" in
  list)        cmd_list ;;
  cleanup)     cmd_cleanup ;;
  detect)      cmd_detect ;;
  drive-only)  cmd_drive_only ;;
  boot-installed) cmd_boot_installed ;;
  provision)   cmd_provision ;;
  *)           die "unknown action: $ACTION" ;;
esac
