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

read_sysfs_value() {
  local path=$1

  if [[ -r "$path" ]]; then
    tr -d '\0' < "$path"
  fi
}

qemu_uefi_guest() {
  local product_name sys_vendor virt

  virt="$(systemd-detect-virt --vm 2>/dev/null || true)"
  sys_vendor="$(read_sysfs_value /sys/class/dmi/id/sys_vendor)"
  product_name="$(read_sysfs_value /sys/class/dmi/id/product_name)"

  [[ -d /sys/firmware/efi/efivars ]] || return 1
  [[ "$virt" == qemu || "$virt" == kvm || "$sys_vendor" == QEMU* || "$product_name" == *QEMU* ]]
}

has_secure_boot_keys() {
  compgen -G '/var/lib/sbctl/keys/PK/*.key' >/dev/null \
    || compgen -G '/usr/share/secureboot/keys/PK/*.key' >/dev/null
}

firmware_setup_mode_enabled() {
  sbctl status 2>/dev/null | grep -Eiq 'Setup Mode:.*Enabled'
}

enroll_secure_boot_keys() {
  if sbctl enroll-keys -m -f; then
    log 'enrolled Secure Boot keys with Microsoft and firmware builtin keys.'
    return 0
  fi

  log 'sbctl could not enroll with firmware builtin keys.'

  if qemu_uefi_guest || [[ "${SBCTL_ALLOW_NO_FIRMWARE_BUILTINS:-0}" == 1 ]]; then
    log 'falling back to Microsoft keys without firmware builtin keys.'
    if sbctl enroll-keys -m; then
      return 0
    fi
  fi

  if qemu_uefi_guest || [[ "${SBCTL_ALLOW_OWNER_ONLY_ENROLLMENT:-0}" == 1 ]]; then
    log 'falling back to owner-only keys with sbctl firmware-risk override.'
    sbctl enroll-keys --yes-this-might-brick-my-machine
    return
  fi

  log 'refusing non-vendor/owner-only Secure Boot enrollment on physical hardware.'
  log 'inspect missing *Default efivars or opt in manually after confirming OptionROM safety.'
  return 1
}

sign_existing_boot_artifacts() {
  local path

  if ! has_secure_boot_keys; then
    log 'local sbctl keys are not available; skipping boot artifact signing.'
    return 0
  fi

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

configure_tpm_unlock_boot() {
  local luks_device luks_uuid mapper_name options root_flags root_fstype console_args

  luks_device=$1
  luks_uuid="$(blkid -s UUID -o value "$luks_device")"
  mapper_name="$(findmnt -no SOURCE / | sed 's|/dev/mapper/||')"
  mapper_name="${mapper_name%%[*}"

  if [[ -z "$luks_uuid" || -z "$mapper_name" ]]; then
    log 'missing LUKS UUID or mapper name; skipping TPM boot configuration.'
    return 0
  fi

  if ! grep -Eq '^HOOKS=.*sd-encrypt' /etc/mkinitcpio.conf; then
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
    log 'switched mkinitcpio hooks from encrypt to sd-encrypt for TPM2 unlock.'
  fi

  root_flags="$(findmnt -no OPTIONS / | tr ',' '\n' | grep '^subvol=' | head -n1 || true)"
  root_fstype="$(findmnt -no FSTYPE / || true)"
  console_args="$(tr ' ' '\n' < /etc/kernel/cmdline 2>/dev/null | grep '^console=' | xargs || true)"
  options="rd.luks.name=$luks_uuid=$mapper_name rd.luks.options=tpm2-device=auto root=/dev/mapper/$mapper_name rw"
  if [[ -n "$root_flags" ]]; then
    options="$options rootflags=$root_flags"
  fi
  if [[ -n "$root_fstype" ]]; then
    options="$options rootfstype=$root_fstype"
  fi
  if [[ -n "$console_args" ]]; then
    options="$options $console_args"
  fi
  printf '%s\n' "$options" > /etc/kernel/cmdline
  log 'updated /etc/kernel/cmdline for systemd TPM2 unlock.'

  mkinitcpio -P
  sign_existing_boot_artifacts
}

root_luks_device() {
  local mapper source

  source="$(findmnt -no SOURCE / || true)"
  if [[ "$source" == /dev/mapper/* ]]; then
    mapper="${source#/dev/mapper/}"
    mapper="${mapper%%[*}"
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
  local luks_device passphrase passphrase_file

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
    configure_tpm_unlock_boot "$luks_device"
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

  passphrase_file="$(mktemp)"
  chmod 600 "$passphrase_file"
  printf '%s' "$passphrase" > "$passphrase_file"
  systemd-cryptenroll "$luks_device" \
    --unlock-key-file="$passphrase_file" \
    --tpm2-device=auto \
    --tpm2-pcrs=7
  shred -u "$passphrase_file" 2>/dev/null || rm -f "$passphrase_file"

  shred -u /etc/ux5606-luks-passphrase 2>/dev/null || rm -f /etc/ux5606-luks-passphrase

  if ! grep -qF 'tpm2-device=auto' /etc/crypttab 2>/dev/null; then
    local mapper_name uuid
    mapper_name="$(findmnt -no SOURCE / | sed 's|/dev/mapper/||')"
    mapper_name="${mapper_name%%[*}"
    uuid="$(blkid -s UUID -o value "$luks_device")"
    if [[ -n "$mapper_name" && -n "$uuid" ]]; then
      printf '%s\tUUID=%s\tnone\ttpm2-device=auto\n' "$mapper_name" "$uuid" >> /etc/crypttab
      log "added /etc/crypttab entry: $mapper_name UUID=$uuid tpm2-device=auto"
    fi
  fi

  configure_tpm_unlock_boot "$luks_device"
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
    else
      log 'firmware is not in Setup Mode; skipping key creation/enrollment.'
      log 'put firmware in Setup Mode, then rerun: sudo systemctl start ux5606-secureboot-tpm-enroll.service'
    fi
  fi

  if firmware_setup_mode_enabled; then
    if ! enroll_secure_boot_keys; then
      sign_existing_boot_artifacts
      log 'key enrollment incomplete; skipping TPM2 PCR7 enrollment and leaving service pending.'
      return 0
    fi
    sign_existing_boot_artifacts
    log 'Secure Boot keys enrolled; reboot once before TPM2 PCR7 enrollment.'
    return 0
  fi

  sign_existing_boot_artifacts
  enroll_tpm_for_root_luks

  touch "$DONE_FILE"
  log 'Secure Boot signing and TPM2 enrollment finished.'
}

main "$@"
