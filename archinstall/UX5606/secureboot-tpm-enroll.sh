#!/usr/bin/env bash
# archinstall/UX5606/secureboot-tpm-enroll.sh
#
# First-boot Secure Boot signing and TPM2 LUKS enrollment for the UX5606 Arch
# install. Linux-only by design: installed as a systemd oneshot service by
# archinstall/UX5606/user_configuration.json.

set -euo pipefail

STATE_DIR=/var/lib/ux5606-install
DONE_FILE="$STATE_DIR/secureboot-tpm.done"

log() {
  printf 'ux5606-secureboot-tpm: %s\n' "$*"
}

has_secure_boot_keys() {
  compgen -G '/usr/share/secureboot/keys/PK/*.key' >/dev/null
}

firmware_setup_mode_enabled() {
  sbctl status 2>/dev/null | grep -Eiq 'Setup Mode:[[:space:]]*(Enabled|✓)'
}

sign_existing_boot_artifacts() {
  local path

  shopt -s nullglob
  for path in \
    /efi/EFI/systemd/systemd-bootx64.efi \
    /boot/EFI/systemd/systemd-bootx64.efi \
    /efi/EFI/BOOT/BOOTX64.EFI \
    /boot/EFI/BOOT/BOOTX64.EFI \
    /efi/EFI/Linux/*.efi \
    /boot/EFI/Linux/*.efi; do
    if [[ -e "$path" ]]; then
      sbctl sign -s "$path"
    fi
  done
  shopt -u nullglob

  while IFS= read -r line; do
    if [[ "$line" =~ (/[^[:space:]]+)[[:space:]]+is[[:space:]]+not[[:space:]]+signed ]]; then
      sbctl sign -s "${BASH_REMATCH[1]}"
    fi
  done < <(sbctl verify 2>&1 || true)
}

root_luks_device() {
  local mapper source

  source="$(findmnt -no SOURCE / || true)"
  if [[ "$source" == /dev/mapper/* ]]; then
    mapper="${source#/dev/mapper/}"
    cryptsetup status "$mapper" 2>/dev/null \
      | awk -F: '/^[[:space:]]*device:/ { gsub(/^[[:space:]]+/, "", $2); print $2; exit }'
    return
  fi

  if [[ -n "$source" ]] && cryptsetup isLuks "$source" 2>/dev/null; then
    printf '%s\n' "$source"
  fi

  return 0
}

enroll_tpm_for_root_luks() {
  local luks_device passphrase

  if [[ ! -e /sys/class/tpm/tpm0 ]]; then
    log 'TPM2 device not found; skipping TPM enrollment.'
    return 0
  fi

  luks_device="$(root_luks_device)"
  if [[ -z "$luks_device" ]]; then
    log 'root filesystem is not detected as LUKS; skipping TPM enrollment.'
    return 0
  fi

  if cryptsetup luksDump "$luks_device" | grep -q 'systemd-tpm2'; then
    log "TPM2 token already enrolled for $luks_device."
    return 0
  fi

  log "enrolling TPM2 token for $luks_device bound to Secure Boot PCR 7."
  if [[ -r /etc/ux5606-luks-passphrase ]]; then
    passphrase="$(head -c 1024 /etc/ux5606-luks-passphrase)"
    log 'using LUKS passphrase from /etc/ux5606-luks-passphrase.'
  else
    passphrase="$(systemd-ask-password "LUKS passphrase for TPM2 enrollment of $luks_device" || true)"
  fi
  if [[ -z "$passphrase" ]]; then
    log 'empty passphrase received; skipping TPM enrollment.'
    return 0
  fi

  printf '%s' "$passphrase" \
    | systemd-cryptenroll "$luks_device" \
      --unlock-key-file=- \
      --tpm2-device=auto \
      --tpm2-pcrs=7

  shred -u /etc/ux5606-luks-passphrase 2>/dev/null || rm -f /etc/ux5606-luks-passphrase

  if ! grep -qF 'tpm2-device=auto' /etc/crypttab 2>/dev/null; then
    local mapper_name uuid
    mapper_name="$(findmnt -no SOURCE / | sed 's|/dev/mapper/||')"
    uuid="$(blkid -s UUID -o value "$luks_device")"
    if [[ -n "$mapper_name" && -n "$uuid" ]]; then
      printf '%s\tUUID=%s\tnone\ttpm2-device=auto\n' "$mapper_name" "$uuid" >> /etc/crypttab
      log "added /etc/crypttab entry: $mapper_name UUID=$uuid tpm2-device=auto"
    fi
  fi
}

main() {
  if [[ "${EUID}" -ne 0 ]]; then
    log 'must run as root.'
    return 1
  fi

  mkdir -p "$STATE_DIR"

  if [[ -e "$DONE_FILE" ]]; then
    log 'already completed.'
    return 0
  fi

  if [[ ! -d /sys/firmware/efi/efivars ]]; then
    log 'system is not booted via UEFI; Secure Boot setup cannot run here.'
    return 0
  fi

  if ! command -v sbctl >/dev/null; then
    log 'sbctl is not installed; Secure Boot setup cannot run.'
    return 0
  fi

  if ! has_secure_boot_keys; then
    if firmware_setup_mode_enabled; then
      sbctl create-keys
      sbctl enroll-keys -m -f
    else
      log 'firmware is not in Setup Mode; skipping key creation/enrollment until the next boot.'
      log 'put firmware in Setup Mode, then rerun: sudo systemctl start ux5606-secureboot-tpm-enroll.service'
      return 0
    fi
  fi

  sign_existing_boot_artifacts
  enroll_tpm_for_root_luks

  touch "$DONE_FILE"
  log 'Secure Boot signing and TPM2 enrollment finished.'
}

main "$@"
