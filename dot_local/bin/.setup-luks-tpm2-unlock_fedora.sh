# Fedora backend for setup-luks-tpm2-unlock.sh — dracut + systemd-cryptenroll.
#
# This fragment is NOT deployed on its own (its source name is dot-prefixed, so
# chezmoi ignores it). It is inlined into the deployed script at apply time by
# the `{{ include }}` in executable_setup-luks-tpm2-unlock.sh.tmpl, mirroring the
# dot_config/git/config.tmpl -> .config_<os> "diverging fragment" pattern.
#
# It provides the four backend hooks the shared core calls (backend_preflight,
# backend_enroll, backend_crypttab_opts, backend_finalize) and may use any shared
# helper/state (SUDO, DRY_RUN, CHANGED, TPM2_PCRS, WITH_RECOVERY_KEY, log_*, err,
# require_cmd). On Fedora/RHEL, dracut is the only initramfs generator that wires
# systemd's `tpm2-device=auto` crypttab unlock into early boot, so enrollment is
# `systemd-cryptenroll` and the crypttab carries `tpm2-device=auto`.

BACKEND_LABEL="dracut + systemd-cryptenroll (Fedora)"

# backend_preflight: verify the dracut TPM2 path is usable BEFORE any irreversible
# enrollment or crypttab edit. No sudo/TTY here — only tool + module availability.
backend_preflight() {
  require_cmd systemd-cryptenroll
  require_cmd dracut
  # Capture-then-match (NOT a pipe into grep -q): under `set -o pipefail`, grep's
  # early exit would SIGPIPE dracut and yield a false negative.
  local dracut_modules
  dracut_modules="$(dracut --list-modules 2>/dev/null || true)"
  if ! grep -qx 'tpm2-tss' <<<"$dracut_modules"; then
    err "ERROR: dracut 'tpm2-tss' module is not available; the initramfs could not"
    err "       unlock via TPM2. Install/repair dracut (Fedora ships this module)"
    err "       and retry. Aborting before making any change."
    exit 1
  fi
}

# backend_enroll <dev> <name> [is_root]: add a TPM2 keyslot/token via
# systemd-cryptenroll. Idempotent — a device already holding a systemd-tpm2 token
# is skipped. The existing passphrase keyslot is never removed.
backend_enroll() {
  local dev="$1" name="$2" dump
  # Capture luksDump then test via herestring (NOT a pipe): under pipefail,
  # `luksDump | grep -q` returns non-zero when grep matches early and luksDump
  # then dies with SIGPIPE — a false negative that would re-enroll.
  dump="$("${SUDO[@]}" cryptsetup luksDump "$dev" 2>/dev/null || true)"
  if grep -q 'systemd-tpm2' <<<"$dump"; then
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

# backend_crypttab_opts <is_root>: the crypttab options systemd-cryptsetup needs
# so it unlocks the device from the TPM at boot. Root gets x-initrd.attach (it
# must attach in the initramfs); non-root gets nofail so an absent device cannot
# hang boot.
backend_crypttab_opts() {
  local is_root="$1"
  if [[ "$is_root" == true ]]; then
    printf 'tpm2-device=auto,x-initrd.attach'
  else
    printf 'tpm2-device=auto,nofail'
  fi
}

# backend_finalize: ensure the dracut tpm2-tss module drop-in exists, then rebuild
# the initramfs (only when something actually changed).
backend_finalize() {
  local conf=/etc/dracut.conf.d/tpm2-tss.conf
  local want='add_dracutmodules+=" tpm2-tss "'
  if "${SUDO[@]}" test -f "$conf" 2>/dev/null && "${SUDO[@]}" grep -qF 'tpm2-tss' "$conf" 2>/dev/null; then
    log_skip "dracut tpm2-tss module already configured ($conf)"
  else
    CHANGED=$((CHANGED + 1))
    if [[ "$DRY_RUN" == true ]]; then
      log_act "would write $conf: $want"
    else
      printf '%s\n' "$want" | "${SUDO[@]}" tee "$conf" >/dev/null
      log_act "wrote $conf"
    fi
  fi

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
