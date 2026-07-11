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
# For that early-boot unlock to actually work, the initramfs must contain the
# `cryptsetup` binary AND be able to reach the TPM. backend_finalize therefore:
#   * forces cryptsetup + cryptroot into the initramfs (ensure_cryptsetup_in_initramfs,
#     CRYPTSETUP=y) — without it there is no `crypt*` executable in the initramfs, the
#     root device is never opened, and boot drops to an (initramfs) shell with
#     "/dev/mapper/... does not exist"; and
#   * pins BOTH the `tss` user (ensure_tss_initramfs_hook) and the TPM kernel driver
#     (ensure_tpm_initramfs_modules) into the initramfs. Without the driver,
#     /dev/tpmrm0 is absent at early boot and the unlock fails even though it
#     succeeded on the running system, the same drop-to-initramfs-shell symptom
#     (clevis issue #136).
# The root device must also be present in /etc/crypttab (backend_crypttab_opts) so
# cryptroot/clevis know which device to open — the installer normally wrote it.
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
  # cryptsetup-initramfs ships the `cryptsetup` binary + cryptroot scripts into
  # the initramfs. clevis-initramfs only *Recommends* it, so on a recommends-off
  # install it can be missing — and then the initramfs has no `crypt*` executable
  # at all, the root LUKS device is never opened, and boot drops to an (initramfs)
  # shell with "/dev/mapper/... does not exist". Refuse to proceed without it
  # rather than rebuild an initramfs that cannot unlock the disk.
  if [[ ! -e /usr/share/initramfs-tools/hooks/cryptsetup ]]; then
    err "ERROR: cryptsetup-initramfs is not installed, so the initramfs would ship"
    err "       without the cryptsetup binary and could not open the root LUKS"
    err "       device at boot. Install it (apt install cryptsetup-initramfs) and"
    err "       retry. Aborting before making any change."
    exit 1
  fi
  if [[ "$WITH_RECOVERY_KEY" == true ]]; then
    log_skip "--recovery-key does not apply to the clevis backend; your existing passphrase remains the fallback"
  fi
}

# backend_enroll <dev> <name> [is_root]: seal a LUKS keyslot to the TPM2 via
# `clevis luks bind`. Idempotent — a device already carrying a clevis tpm2 binding
# is skipped. By default clevis prompts for an existing passphrase itself; when a
# passphrase was supplied via the environment (PASSPHRASE_FROM_ENV, see the
# shared core), it is fed on stdin instead so enrollment runs unattended.
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
  if [[ "$PASSPHRASE_FROM_ENV" == true ]]; then
    # Non-interactive: feed the supplied passphrase on stdin (-k -) and
    # auto-confirm (-y) so no prompt blocks an unattended enrollment.
    log_act "$dev ($name): binding clevis TPM2 (config $cfg) using the supplied passphrase"
    printf '%s' "$PASSPHRASE" | "${SUDO[@]}" clevis luks bind -y -k - -d "$dev" tpm2 "$cfg"
  else
    log_act "$dev ($name): binding clevis TPM2 (config $cfg) — enter an existing passphrase when prompted"
    "${SUDO[@]}" clevis luks bind -d "$dev" tpm2 "$cfg"
  fi
}

# backend_crypttab_opts <is_root>: the root device MUST have an /etc/crypttab
# entry — both cryptsetup-initramfs (which reads crypttab to decide the initramfs
# needs cryptsetup) and clevis-initramfs (whose early-boot hook iterates crypttab
# entries and clevis-unlocks each) key off it. On a normal encrypted install the
# installer already wrote this entry, so `luks` merges in as a no-op; we return it
# (not empty) so a MISSING root entry is repaired instead of silently leaving a
# disk the initramfs never tries to open. A non-root device is marked _netdev so
# clevis's systemd askpass path unlocks it after boot instead of blocking it.
backend_crypttab_opts() {
  local is_root="$1"
  if [[ "$is_root" == true ]]; then
    printf 'luks'
  else
    printf 'luks,_netdev'
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

# ensure_tpm_initramfs_modules: clevis's early-boot TPM2 unlock needs a TPM
# character device (/dev/tpmrm0) present in the initramfs, which only exists once
# the kernel's TPM interface driver (tpm_crb / tpm_tis, on top of the tpm core) is
# loaded. Ubuntu's default MODULES=dep initramfs frequently OMITS that driver, so
# `clevis luks bind`/`unlock` succeed on the RUNNING system (driver already loaded)
# yet the SAME unlock fails at early boot: the TPM device is absent, clevis cannot
# retrieve the key, the root LUKS device is never opened and boot drops to an
# initramfs shell with "/dev/mapper/... does not exist" (clevis issue #136 — the
# Ubuntu-specific "works at enrollment, fails at boot" failure). Pin the TPM
# driver(s) into the initramfs via /etc/initramfs-tools/modules so the device is
# available when clevis runs.
#
# Prefer the tpm* driver(s) actually loaded now — enrollment on this host proves
# they back its TPM — then fall back to the common core + CRB/TIS interface set.
# Only modules the running kernel actually ships are written (filtered via
# modinfo), so update-initramfs never chokes on an unknown module name; a TPM
# driver built into the kernel (no module) cleanly yields nothing to add.
# Idempotent via a managed marker; counts as a change so the initramfs is rebuilt.
ensure_tpm_initramfs_modules() {
  local modfile=/etc/initramfs-tools/modules
  local marker='# clevis TPM2 early-boot access (managed by setup-luks-tpm2-unlock.sh)'
  if "${SUDO[@]}" grep -qF "$marker" "$modfile" 2>/dev/null; then
    log_skip "initramfs TPM modules already configured ($modfile)"
    return 0
  fi
  # Candidates: TPM drivers loaded now (best signal) + the usual core/CRB/TIS set.
  local -a candidates=() resolved=()
  local m seen=" "
  while IFS= read -r m; do
    [[ -n "$m" ]] && candidates+=("$m")
  done < <(lsmod 2>/dev/null | awk 'NR>1 && $1 ~ /^tpm/ {print $1}')
  candidates+=(tpm tpm_crb tpm_tis)
  # Keep only modules the running kernel actually provides, de-duplicated, so a
  # name that does not apply here can never make update-initramfs fail.
  for m in "${candidates[@]}"; do
    case "$seen" in *" $m "*) continue ;; esac
    if modinfo "$m" >/dev/null 2>&1; then
      resolved+=("$m")
      seen+="$m "
    fi
  done
  if [[ "${#resolved[@]}" -eq 0 ]]; then
    log_skip "no loadable TPM kernel module found (built-in or absent); no $modfile entry needed"
    return 0
  fi
  CHANGED=$((CHANGED + 1))
  if [[ "$DRY_RUN" == true ]]; then
    log_act "would add TPM module(s) to $modfile: ${resolved[*]}"
    return 0
  fi
  {
    printf '%s\n' "$marker"
    printf '%s\n' "${resolved[@]}"
  } | "${SUDO[@]}" tee -a "$modfile" >/dev/null
  log_act "added TPM module(s) to $modfile: ${resolved[*]}"
}

# ensure_cryptsetup_in_initramfs: force the `cryptsetup` binary + cryptroot scripts
# into the initramfs. cryptsetup-initramfs's hook otherwise only bundles them when
# its heuristic decides a LUKS device is needed at boot (it parses /etc/crypttab and
# /etc/fstab); when that detection misfires it prints "cryptsetup: WARNING: could not
# determine root device" and ships an initramfs with NO `crypt*` executable — so the
# root device is never opened and boot drops to an (initramfs) shell. Setting
# CRYPTSETUP=y in /etc/cryptsetup-initramfs/conf-hook makes the hook include cryptsetup
# UNCONDITIONALLY, which is the robust fix for the "no cryptsetup in the initramfs"
# failure. Idempotent (skips when already forced on); counts as a change so the
# initramfs is rebuilt. The file is sourced by the hook, so a later CRYPTSETUP=y wins
# over any earlier CRYPTSETUP=n the distro/user may have set.
ensure_cryptsetup_in_initramfs() {
  local conf=/etc/cryptsetup-initramfs/conf-hook
  if "${SUDO[@]}" grep -Eq '^[[:space:]]*CRYPTSETUP=y([[:space:]]|$)' "$conf" 2>/dev/null; then
    log_skip "initramfs already forces cryptsetup inclusion ($conf)"
    return 0
  fi
  CHANGED=$((CHANGED + 1))
  if [[ "$DRY_RUN" == true ]]; then
    log_act "would set CRYPTSETUP=y in $conf (force cryptsetup into the initramfs)"
    return 0
  fi
  "${SUDO[@]}" mkdir -p "$(dirname "$conf")"
  {
    printf '%s\n' '# Force cryptsetup + cryptroot into the initramfs so the root LUKS device can be'
    printf '%s\n' '# opened at early boot (managed by setup-luks-tpm2-unlock.sh).'
    printf '%s\n' 'CRYPTSETUP=y'
  } | "${SUDO[@]}" tee -a "$conf" >/dev/null
  log_act "set CRYPTSETUP=y in $conf"
}

# backend_finalize: make the initramfs able to open the root LUKS device at early
# boot — bundle the cryptsetup binary (ensure_cryptsetup_in_initramfs) and let it
# reach the TPM (the tss user + the TPM kernel driver) — then rebuild the initramfs
# (only when something actually changed).
backend_finalize() {
  ensure_cryptsetup_in_initramfs
  ensure_tss_initramfs_hook
  ensure_tpm_initramfs_modules

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
