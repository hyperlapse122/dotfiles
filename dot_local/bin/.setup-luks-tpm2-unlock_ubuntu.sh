# Ubuntu backend for setup-luks-tpm2-unlock.sh — clevis + initramfs-tools.
#
# This fragment is NOT deployed on its own (its source name is dot-prefixed, so
# chezmoi ignores it). It is inlined into the deployed script at apply time by
# the `{{ include }}` in executable_setup-luks-tpm2-unlock.sh.tmpl, mirroring the
# dot_config/git/config.tmpl -> .config_<os> "diverging fragment" pattern.
#
# WHY clevis (not systemd-cryptenroll) on Ubuntu: Ubuntu ships initramfs-tools,
# whose cryptroot scripts use plain cryptsetup and silently ignore the
# systemd-cryptsetup `tpm2-device=auto` crypttab option (Launchpad #1980018) —
# a systemd-cryptenroll enrollment would leave a passphrase prompt at boot while
# appearing to succeed. clevis is the initramfs-tools-native path: `clevis luks
# bind` seals a LUKS keyslot to the TPM2, and the clevis-initramfs hook unlocks
# the root device in early boot without any crypttab change. The existing
# passphrase keyslot is untouched, so it remains the fallback.
#
# It provides the four backend hooks the shared core calls (backend_preflight,
# backend_enroll, backend_crypttab_opts, backend_finalize) and may use any shared
# helper/state (SUDO, DRY_RUN, CHANGED, TPM2_PCRS, WITH_RECOVERY_KEY, log_*, err,
# require_cmd).

BACKEND_LABEL="clevis + initramfs-tools (Ubuntu)"

# backend_preflight: verify the clevis TPM2 path is usable BEFORE any irreversible
# bind or crypttab edit. No sudo/TTY here — only tool + hook availability.
backend_preflight() {
  require_cmd clevis
  require_cmd clevis-encrypt-tpm2   # from clevis-tpm2 (pulls tpm2-tools)
  require_cmd update-initramfs      # initramfs-tools
  # The clevis-initramfs hook is what actually unlocks root in early boot;
  # without it a bind would succeed but the disk would still prompt at boot.
  if [[ ! -e /usr/share/initramfs-tools/hooks/clevis ]]; then
    err "ERROR: clevis-initramfs is not installed, so the root device would not"
    err "       auto-unlock at boot. Install it (apt install clevis-initramfs)"
    err "       and retry. Aborting before making any change."
    exit 1
  fi
  if [[ "$WITH_RECOVERY_KEY" == true ]]; then
    log_skip "--recovery-key does not apply to the clevis backend; your existing passphrase remains the fallback"
  fi
}

# backend_enroll <dev> <name> [is_root]: seal a LUKS keyslot to the TPM2 via
# `clevis luks bind`. Idempotent — a device already carrying a clevis tpm2 binding
# is skipped. clevis prompts for an existing passphrase itself (interactive-only,
# same guarantee as the Fedora path).
backend_enroll() {
  local dev="$1" name="$2" listing cfg pcr_ids
  # `clevis luks list` reads the LUKS2 header tokens (needs root); capture then
  # match via herestring to stay pipefail-safe.
  listing="$("${SUDO[@]}" clevis luks list -d "$dev" 2>/dev/null || true)"
  if grep -q 'tpm2' <<<"$listing"; then
    log_skip "$dev ($name): already has a clevis tpm2 binding; skipping enrollment"
    return 0
  fi
  # Map the systemd-style PCR spec (e.g. 7, 7+0, or empty) to clevis pcr_ids
  # (comma-separated). Empty spec => no PCR binding.
  pcr_ids="${TPM2_PCRS//+/,}"
  if [[ -n "$pcr_ids" ]]; then
    cfg="$(printf '{"pcr_bank":"sha256","pcr_ids":"%s"}' "$pcr_ids")"
  else
    cfg='{}'
  fi
  CHANGED=$((CHANGED + 1))
  if [[ "$DRY_RUN" == true ]]; then
    log_act "$dev ($name): would run clevis luks bind -d $dev tpm2 '$cfg'"
    return 0
  fi
  log_act "$dev ($name): binding clevis TPM2 (config $cfg) — enter an existing passphrase when prompted"
  "${SUDO[@]}" clevis luks bind -d "$dev" tpm2 "$cfg"
}

# backend_crypttab_opts <is_root>: clevis needs NO crypttab change for the root
# device — clevis-initramfs unlocks it in early boot. A non-root device is marked
# _netdev so clevis's systemd askpass path unlocks it after boot instead of
# blocking it. Root => empty (leave crypttab untouched).
backend_crypttab_opts() {
  local is_root="$1"
  if [[ "$is_root" == true ]]; then
    printf ''
  else
    printf '_netdev'
  fi
}

# ensure_tss_initramfs_hook: clevis-initramfs does not copy the `tss` user/group
# into the initramfs, so tpm2-tss cannot open the TPM during early-boot unlock.
# Drop a small initramfs-tools hook that copies them in. Idempotent (written only
# when missing); counts as a change so the initramfs is rebuilt.
ensure_tss_initramfs_hook() {
  local hook=/etc/initramfs-tools/hooks/tss-user
  if "${SUDO[@]}" test -x "$hook" 2>/dev/null; then
    log_skip "initramfs tss-user hook already present ($hook)"
    return 0
  fi
  CHANGED=$((CHANGED + 1))
  if [[ "$DRY_RUN" == true ]]; then
    log_act "would write $hook (copies the tss user/group into the initramfs)"
    return 0
  fi
  "${SUDO[@]}" tee "$hook" >/dev/null <<'HOOK'
#!/bin/sh
# Copy the tss user/group into the initramfs so tpm2-tss can open the TPM during
# early-boot clevis unlock (clevis-initramfs omits them). Managed by
# setup-luks-tpm2-unlock.sh.
PREREQ="clevis"
prereqs() { echo "$PREREQ"; }
case "$1" in
  prereqs) prereqs; exit 0 ;;
esac
. /usr/share/initramfs-tools/hook-functions
if ! grep -q '^tss:' "${DESTDIR}/etc/passwd" 2>/dev/null; then
  grep '^tss:' /etc/passwd >>"${DESTDIR}/etc/passwd" || true
fi
if ! grep -q '^tss:' "${DESTDIR}/etc/group" 2>/dev/null; then
  grep '^tss:' /etc/group >>"${DESTDIR}/etc/group" || true
fi
HOOK
  "${SUDO[@]}" chmod 0755 "$hook"
  log_act "wrote $hook"
}

# backend_finalize: ensure the tss-user initramfs hook exists, then rebuild the
# initramfs (only when something actually changed).
backend_finalize() {
  ensure_tss_initramfs_hook

  if [[ "$CHANGED" -eq 0 ]]; then
    log_skip "nothing changed; skipping initramfs rebuild"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log_act "would rebuild initramfs: update-initramfs -u -k all"
    return 0
  fi
  log_act "rebuilding initramfs (update-initramfs -u -k all)"
  "${SUDO[@]}" update-initramfs -u -k all
}
