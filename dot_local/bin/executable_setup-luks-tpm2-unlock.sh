#!/usr/bin/env bash
# setup-luks-tpm2-unlock.sh — TPM2-backed automatic LUKS unlock at boot.
#
# Set up TPM2-backed automated unlocking for EVERY LUKS-encrypted block device
# on the currently-running system (the device backing / included). For each
# crypto_LUKS device it:
#
#   1. enrolls a TPM2 token via `systemd-cryptenroll --tpm2-device=auto
#      --tpm2-pcrs=7` (PCR 7 = the UEFI Secure Boot policy state), prompting
#      INTERACTIVELY for an existing LUKS passphrase to authorize the change;
#   2. ensures /etc/crypttab carries `tpm2-device=auto` (plus `x-initrd.attach`
#      for the root-backing device, or `nofail` for non-root devices so a
#      device that is absent at boot cannot hang the boot) so systemd-cryptsetup
#      unlocks it from the TPM at boot;
#   3. drops a dracut `tpm2-tss` module config and rebuilds the initramfs so the
#      TPM2 token plugin is present early at boot.
#
# INTERACTIVE-ONLY PASSPHRASE (hard requirement): the existing passphrase is
# only ever typed at systemd-cryptenroll's own prompt. This script never reads
# it from argv/env/file — it does NOT set $PASSWORD / $NEWPASSWORD, never passes
# --unlock-key-file, and never uses the cryptenroll.passphrase /
# cryptenroll.new-passphrase service credentials. Because it must prompt, it
# REQUIRES a TTY (except under --dry-run) and is therefore a MANUAL script: it
# is deliberately NOT a chezmoi run_once_/run_onchange_ script — chezmoi runs
# those non-interactively during `chezmoi apply` and could neither answer the
# passphrase prompt nor be trusted to enroll a TPM2 keyslot unattended. chezmoi
# instead deploys it (via the executable_ source-name prefix) to ~/.local/bin,
# which is on $PATH; run it by hand after a fresh install:
#
#     setup-luks-tpm2-unlock.sh
#
# SAFETY: `systemd-cryptenroll` ADDS a TPM2 keyslot/token; it does NOT remove
# the existing passphrase keyslot. The current passphrase therefore stays valid
# as a fallback if the TPM is later cleared or the firmware/Secure-Boot state
# changes. `--recovery-key` additionally enrolls a printed recovery key. To
# re-enroll a device that already holds a (possibly stale) systemd-tpm2 token,
# first wipe it with `systemd-cryptenroll --wipe-slot=tpm2 <device>` — this
# script skips any device that already has such a token.
#
# PCR CHOICE: this runs from the INSTALLED system, so PCR 7 measured here equals
# PCR 7 at the next real boot (same Secure Boot policy) — binding is safe. Note:
# on systemd v258+ the default --tpm2-pcrs is EMPTY (no binding), so PCR 7 is
# passed EXPLICITLY rather than relying on the default. Override with
# --tpm2-pcrs (e.g. `7+0`, or `` for no binding) if you know what you want.
#
# Single-platform (Linux only) BY DESIGN — LUKS, systemd-cryptenroll and dracut
# are Linux-only, so per the script-parity exception in AGENTS.md there is no
# .ps1 counterpart. It is deployed to ~/.local/bin on every POSIX host but is
# harmlessly dormant anywhere systemd-cryptenroll/dracut are absent (it aborts
# at the require_cmd preflight).
#
# IDEMPOTENT: a device that already holds a `systemd-tpm2` token is skipped;
# /etc/crypttab entries are matched by exact device alias (UUID=, PARTUUID=, raw
# path, or any /dev/disk/* symlink) so options are merged into the existing
# entry and never duplicated; the dracut drop-in is only written when missing;
# the initramfs is rebuilt only when something actually changed. /etc/crypttab
# is backed up before the first edit and written atomically (temp file in /etc +
# rename) so an interrupted run cannot truncate this boot-critical file.
#
# --dry-run prints every intended action and mutates NOTHING (no enrollment, no
# crypttab write, no dracut config, no initramfs rebuild).

set -euo pipefail

# ---------------------------------------------------------------------------
# Pure, side-effect-free helpers. The file is sourceable (see the main-guard at
# the bottom), so these can be exercised in isolation without the side-effecting
# flow running.
# ---------------------------------------------------------------------------

# merge_crypttab_opts <existing-opts> <wanted-opts>
# Merge comma-separated crypttab option lists. Dedupe by OPTION KEY (the text
# before '='), so an existing `tpm2-device=/dev/tpmrm0` is respected and the
# wanted `tpm2-device=auto` is NOT appended as a second tpm2-device key (which
# systemd-cryptsetup would reject). A `-`/`none`/empty existing field is
# replaced wholesale by the wanted options. Existing order is preserved.
merge_crypttab_opts() {
  local existing="$1" want="$2"
  if [[ -z "$existing" || "$existing" == "-" || "$existing" == "none" ]]; then
    printf '%s' "$want"
    return
  fi
  local -a want_arr exist_arr
  IFS=',' read -ra want_arr <<<"$want"
  IFS=',' read -ra exist_arr <<<"$existing"
  local result="$existing" tok et tkey ekey present
  for tok in "${want_arr[@]}"; do
    tkey="${tok%%=*}"
    present=false
    for et in "${exist_arr[@]}"; do
      ekey="${et%%=*}"
      [[ "$ekey" == "$tkey" ]] && { present=true; break; }
    done
    [[ "$present" == false ]] && result="${result},${tok}"
  done
  printf '%s' "$result"
}

# render_crypttab <name> <canonical-src> <want-opts> [match-alias...]
# Read current /etc/crypttab content on stdin, print the desired content on
# stdout. An entry matches when its name field equals <name> OR its source field
# (field 2) EXACTLY equals <canonical-src> or any <match-alias> (UUID=, PARTUUID=,
# raw device path, /dev/disk/* symlink). Matching is exact — never substring —
# so we never false-match nor append a duplicate entry for a device already
# present under a different source form. Matched entries get <want-opts> merged
# (see merge_crypttab_opts). Comments, blank lines and unrelated entries pass
# through verbatim. When nothing matches, a canonical `<name> <canonical-src> -
# <want-opts>` line is appended.
render_crypttab() {
  local name="$1" canonical="$2" want="$3"
  shift 3
  local -a aliases=("$@")
  local found=false line trimmed f1 f2 f3 f4 a match
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ -z "${line//[[:space:]]/}" || "$trimmed" == \#* ]]; then
      printf '%s\n' "$line"
      continue
    fi
    f1=""; f2=""; f3=""; f4=""
    read -r f1 f2 f3 f4 <<<"$line"
    match=false
    if [[ "$f1" == "$name" || "$f2" == "$canonical" ]]; then
      match=true
    else
      for a in "${aliases[@]}"; do
        [[ "$f2" == "$a" ]] && { match=true; break; }
      done
    fi
    if [[ "$match" == true ]]; then
      found=true
      printf '%s %s %s %s\n' "$f1" "$f2" "${f3:--}" "$(merge_crypttab_opts "${f4:-}" "$want")"
    else
      printf '%s\n' "$line"
    fi
  done
  if [[ "$found" != true ]]; then
    printf '%s %s - %s\n' "$name" "$canonical" "$want"
  fi
}

# luksdump_has_tpm2_token : reads `cryptsetup luksDump` text on stdin, exits 0
# if a systemd-tpm2 token is already enrolled, 1 otherwise.
luksdump_has_tpm2_token() {
  grep -q 'systemd-tpm2'
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_act()  { printf '  -> %s\n' "$*"; }
log_skip() { printf '  -- %s\n' "$*"; }
log_info() { printf '%s\n' "$*"; }
err()      { printf '%s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: setup-luks-tpm2-unlock.sh [OPTIONS]

TPM2-enroll every LUKS device on this running system for automated unlock at
boot. Prompts interactively for each device's existing passphrase.

Options:
  --dry-run            Print intended actions; change nothing.
  --recovery-key       Also enroll a printed recovery key as an extra fallback.
  --tpm2-pcrs SPEC     PCR binding spec (default: 7). Examples: 7, 7+0, ''(none).
  -h, --help           Show this help and exit.

Notes:
  * Requires a terminal (it must prompt for your passphrase) unless --dry-run.
  * Adds a TPM2 keyslot; your existing passphrase keeps working as a fallback.
  * Idempotent: devices already holding a systemd-tpm2 token are skipped.
EOF
}

# ---------------------------------------------------------------------------
# Side-effecting flow
# ---------------------------------------------------------------------------

DRY_RUN=false
WITH_RECOVERY_KEY=false
TPM2_PCRS=7
SUDO=()
CHANGED=0
CRYPTTAB_BACKED_UP=false
ROOT_KNAME=""

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "ERROR: required command not found: $1"; exit 1; }
}

# device_is_root <dev> : true when <dev> (or any of its device-mapper
# descendants — LUKS, or LUKS->LVM->root) is the block device backing /.
# Compares by kernel name (KNAME) so it is immune to mapper-name vs dm-N vs
# symlink differences.
device_is_root() {
  local dev="$1" kn
  [[ -z "$ROOT_KNAME" ]] && return 1
  while IFS= read -r kn; do
    [[ "$kn" == "$ROOT_KNAME" ]] && return 0
  done < <(lsblk -rno KNAME "$dev" 2>/dev/null)
  return 1
}

# device_aliases <dev> <uuid> : print, one per line, every crypttab source form
# that can reference <dev> — UUID=, PARTUUID=, the raw path, its realpath, and
# every /dev/disk/* symlink (by-uuid/by-partuuid/by-id/by-path) resolving to it.
# Used for EXACT (never substring) matching of an existing crypttab entry.
device_aliases() {
  local dev="$1" uuid="$2" real partuuid link resolved
  real="$(readlink -f "$dev" 2>/dev/null || true)"
  printf '%s\n' "UUID=$uuid" "$dev"
  [[ -n "$real" && "$real" != "$dev" ]] && printf '%s\n' "$real"
  partuuid="$(lsblk -dno PARTUUID "$dev" 2>/dev/null || true)"
  [[ -n "$partuuid" ]] && printf '%s\n' "PARTUUID=$partuuid"
  for link in /dev/disk/*/*; do
    [[ -e "$link" ]] || continue
    resolved="$(readlink -f "$link" 2>/dev/null || true)"
    [[ -n "$real" && "$resolved" == "$real" ]] && printf '%s\n' "$link"
  done
}

enroll_device() {
  local dev="$1" name="$2" dump
  # Capture luksDump then test via herestring (NOT a pipe): under `set -o
  # pipefail`, `luksDump | grep -q` returns non-zero when grep matches early and
  # luksDump then dies with SIGPIPE — a false negative that would re-enroll an
  # already-enrolled device.
  dump="$("${SUDO[@]}" cryptsetup luksDump "$dev" 2>/dev/null || true)"
  if luksdump_has_tpm2_token <<<"$dump"; then
    log_skip "$dev ($name): already has a systemd-tpm2 token; skipping enrollment"
    return 0
  fi
  CHANGED=$((CHANGED + 1))
  if [[ "$DRY_RUN" == true ]]; then
    log_act "$dev ($name): would run systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=$TPM2_PCRS"
    [[ "$WITH_RECOVERY_KEY" == true ]] && log_act "$dev ($name): would enroll a recovery key"
    return 0
  fi
  log_act "$dev ($name): enrolling TPM2 (PCR $TPM2_PCRS) — enter an existing passphrase when prompted"
  "${SUDO[@]}" systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs="$TPM2_PCRS" "$dev"
  if [[ "$WITH_RECOVERY_KEY" == true ]]; then
    log_act "$dev ($name): enrolling recovery key — record the printed key safely"
    "${SUDO[@]}" systemd-cryptenroll --recovery-key "$dev"
  fi
}

# update_crypttab <name> <canonical-src> <want-opts> [alias...]
update_crypttab() {
  local name="$1" canonical="$2" want="$3"
  shift 3
  local -a aliases=("$@")
  local current new tmp
  current="$("${SUDO[@]}" cat /etc/crypttab 2>/dev/null || true)"
  new="$(printf '%s' "$current" | render_crypttab "$name" "$canonical" "$want" "${aliases[@]}")"
  if [[ "$current" == "$new" ]]; then
    log_skip "/etc/crypttab already correct for $name"
    return 0
  fi
  CHANGED=$((CHANGED + 1))
  if [[ "$DRY_RUN" == true ]]; then
    log_act "would update /etc/crypttab entry for $name:"
    printf '%s\n' "$new" | grep -F -e "$canonical" -e "$name" | sed 's/^/        /' || true
    return 0
  fi
  if [[ "$CRYPTTAB_BACKED_UP" != true ]]; then
    if "${SUDO[@]}" test -e /etc/crypttab; then
      local backup
      backup="/etc/crypttab.bak.$(date +%Y%m%d%H%M%S)"
      "${SUDO[@]}" cp -a /etc/crypttab "$backup"
      log_act "backed up /etc/crypttab -> $backup"
    else
      log_skip "no existing /etc/crypttab to back up"
    fi
    CRYPTTAB_BACKED_UP=true
  fi
  # Atomic replace: write a temp file ON THE SAME FILESYSTEM (/etc), match the
  # existing mode/owner (or 0600 root when creating), then rename into place so
  # an interrupted/failed write can never truncate /etc/crypttab.
  tmp="$("${SUDO[@]}" mktemp /etc/crypttab.tmp.XXXXXX)"
  printf '%s\n' "$new" | "${SUDO[@]}" tee "$tmp" >/dev/null
  if "${SUDO[@]}" test -e /etc/crypttab; then
    "${SUDO[@]}" chmod --reference=/etc/crypttab "$tmp"
    "${SUDO[@]}" chown --reference=/etc/crypttab "$tmp"
  else
    "${SUDO[@]}" chmod 0600 "$tmp"
    "${SUDO[@]}" chown 0:0 "$tmp"
  fi
  "${SUDO[@]}" mv -f "$tmp" /etc/crypttab
  log_act "updated /etc/crypttab for $name"
}

ensure_dracut_tpm2() {
  local conf=/etc/dracut.conf.d/tpm2-tss.conf
  local want='add_dracutmodules+=" tpm2-tss "'
  if "${SUDO[@]}" test -f "$conf" 2>/dev/null && "${SUDO[@]}" grep -qF 'tpm2-tss' "$conf" 2>/dev/null; then
    log_skip "dracut tpm2-tss module already configured ($conf)"
    return 0
  fi
  CHANGED=$((CHANGED + 1))
  if [[ "$DRY_RUN" == true ]]; then
    log_act "would write $conf: $want"
    return 0
  fi
  printf '%s\n' "$want" | "${SUDO[@]}" tee "$conf" >/dev/null
  log_act "wrote $conf"
}

rebuild_initramfs() {
  if [[ "$CHANGED" -eq 0 ]]; then
    log_skip "nothing changed; skipping initramfs rebuild"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log_act "would rebuild initramfs: dracut -f --regenerate-all"
    return 0
  fi
  log_act "rebuilding initramfs (dracut -f --regenerate-all)"
  "${SUDO[@]}" dracut -f --regenerate-all
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)        DRY_RUN=true ;;
      --recovery-key)   WITH_RECOVERY_KEY=true ;;
      --tpm2-pcrs)      shift; [[ $# -gt 0 ]] || { err "ERROR: --tpm2-pcrs requires a value"; exit 2; }; TPM2_PCRS="$1" ;;
      --tpm2-pcrs=*)    TPM2_PCRS="${1#*=}" ;;
      -h|--help)        usage; exit 0 ;;
      *)                err "ERROR: unknown option: $1"; err ""; usage >&2; exit 2 ;;
    esac
    shift
  done

  # Interactive passphrase entry needs a terminal. Allow --dry-run without one.
  if [[ "$DRY_RUN" != true && ! -t 0 ]]; then
    err "ERROR: this script needs an interactive terminal to prompt for your LUKS"
    err "       passphrase. Run it directly in a terminal, or use --dry-run to preview."
    exit 1
  fi

  # dry-run uses `sudo -n` so its read-only probes never prompt/hang; a real run
  # primes the credential cache once so the only later prompts are
  # systemd-cryptenroll's per-device passphrase prompts.
  if [[ "${EUID}" -eq 0 ]]; then
    SUDO=()
  elif ! command -v sudo >/dev/null 2>&1; then
    err "ERROR: not running as root and sudo is not available; cannot enroll TPM2."
    exit 1
  elif [[ "$DRY_RUN" == true ]]; then
    SUDO=(sudo -n)
  else
    SUDO=(sudo)
  fi
  if [[ "$DRY_RUN" != true && "${#SUDO[@]}" -gt 0 ]]; then
    "${SUDO[@]}" -v || { err "ERROR: sudo authentication failed"; exit 1; }
  fi

  require_cmd systemd-cryptenroll
  require_cmd cryptsetup
  require_cmd dracut
  require_cmd lsblk
  require_cmd findmnt
  require_cmd readlink

  # TPM2 presence: a kernel TPM2 device node or a systemd-detected device.
  if [[ ! -e /sys/class/tpm/tpm0 ]] && ! systemd-cryptenroll --tpm2-device=list >/dev/null 2>&1; then
    err "ERROR: no TPM2 device found (no /sys/class/tpm/tpm0 and systemd-cryptenroll"
    err "       --tpm2-device=list reports none). TPM2 auto-unlock is not possible here."
    exit 1
  fi

  # Preflight the dracut tpm2-tss module BEFORE any irreversible enrollment or
  # crypttab edit — without it the rebuilt initramfs can't unlock via TPM2 and
  # we would have changed state for nothing. Capture-then-match (not a pipe into
  # grep -q): pipefail + grep's early exit would SIGPIPE dracut → false negative.
  local dracut_modules
  dracut_modules="$(dracut --list-modules 2>/dev/null || true)"
  if ! grep -qx 'tpm2-tss' <<<"$dracut_modules"; then
    err "ERROR: dracut 'tpm2-tss' module is not available; the initramfs could not"
    err "       unlock via TPM2. Install/repair dracut (Fedora ships this module)"
    err "       and retry. Aborting before making any change."
    exit 1
  fi

  # Enumerate crypto_LUKS devices (lsblk needs no root for this).
  local -a devices=()
  mapfile -t devices < <(lsblk -rno PATH,FSTYPE 2>/dev/null | awk '$2=="crypto_LUKS"{print $1}' | sort -u)
  if [[ "${#devices[@]}" -eq 0 ]]; then
    log_info "No crypto_LUKS devices found; nothing to do."
    exit 0
  fi

  # Kernel name (e.g. dm-0) of the block device backing /, for ancestry-based
  # root detection. A btrfs '[subvol]' suffix is stripped first.
  local root_src
  root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  root_src="${root_src%%[*}"
  ROOT_KNAME="$(lsblk -no KNAME "$root_src" 2>/dev/null | head -n1 || true)"

  log_info "Found ${#devices[@]} crypto_LUKS device(s)."
  [[ "$DRY_RUN" == true ]] && log_info "(dry-run: no changes will be made)"

  local dev uuid name is_root want canonical
  local -a aliases
  for dev in "${devices[@]}"; do
    # -d (--nodeps) is REQUIRED: without it lsblk recurses into the opened
    # mapping and may emit the inner filesystem UUID, not the LUKS header UUID
    # that /etc/crypttab keys by — keying by the wrong UUID breaks boot.
    uuid="$(lsblk -dno UUID "$dev" 2>/dev/null | head -n1 || true)"
    if [[ -z "$uuid" ]]; then
      log_skip "$dev: could not read LUKS UUID; skipping"
      continue
    fi
    name="$(lsblk -rno NAME "$dev" 2>/dev/null | awk 'NR==2{print}')"
    [[ -z "$name" ]] && name="luks-$uuid"

    if device_is_root "$dev"; then
      is_root=true
      want="tpm2-device=auto,x-initrd.attach"
    else
      is_root=false
      want="tpm2-device=auto,nofail"
    fi
    canonical="UUID=$uuid"
    mapfile -t aliases < <(device_aliases "$dev" "$uuid")

    log_info ""
    log_info "Device $dev (name=$name, uuid=$uuid, root=$is_root)"
    enroll_device "$dev" "$name"
    update_crypttab "$name" "$canonical" "$want" "${aliases[@]}"
  done

  log_info ""
  ensure_dracut_tpm2
  rebuild_initramfs

  log_info ""
  if [[ "$DRY_RUN" == true ]]; then
    log_info "Dry run complete. Re-run without --dry-run to apply."
  else
    log_info "Done. Reboot to verify the TPM2 automatically unlocks your disk(s)."
    log_info "Your existing passphrase still works as a fallback."
  fi
}

# Run main only when executed, not when sourced (so the pure helpers above can
# be imported in isolation without triggering the side-effecting flow).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
