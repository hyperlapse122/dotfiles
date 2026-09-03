#!/usr/bin/env bash

# Assert the Fedora DKMS MOK contract against rendered provisioning output.
#
# The DKMS MOK at /var/lib/dkms/mok.{pub,key} is the trust anchor the NVIDIA
# DKMS driver signs against, and mokutil enrollment is what makes the firmware
# accept it. This guards the one way that anchor can be destroyed: a keypair
# probe that reads "sudo could not run" as "no key is present" and mints a fresh
# pair over the enrolled one, stranding the enrolled certificate without its
# private key. It also holds the retired VirtualBox module-signing path retired —
# the kernel-install hook that scanned the wrong module directory and could not
# build for a non-running kernel, and the hand-rolled sign-file loop that
# replaced it. VirtualBox itself is no longer a managed package.
#
# The MOK state and mint helpers are executed for real against a scratch tree
# with stubbed sudo and openssl; the environment guards inside
# ensure_dkms_mok_generated are asserted as rendered text, because
# `/sys/firmware/efi` and the Secure Boot probe are not relocatable.
#
# BOTH BUILD SYSTEMS, not just DKMS. The driver-branch axis gave the legacy branch
# its own out-of-tree builder and its own certificate under /etc/pki/akmods, and
# this harness used to pin nvidia_build_system to `dkms` and rewrite only the
# /var/lib/dkms paths -- so cert_path_for_marker, the akmods paths,
# report_stale_mok and the awaiting-builder branch had never run in CI, and both
# MOK defects fixed alongside them reached review through that gap. The state and
# mint assertions now loop over both build systems, and the akmods tree is
# relocated the same way the DKMS one is.
#
# AND THE ENROLLMENT ITSELF. `mokutil --import` reads a one-time password from a
# terminal an apply does not have, so it is driven through expect with the stored
# passphrase in the ENVIRONMENT. Every precondition (no stored passphrase, no
# expect, a passphrase that cannot be typed on the MokManager console) is a
# declared skip that prints the by-hand command, and the import's exit status is
# propagated. All of that is asserted below, including that the passphrase never
# reaches an argument vector.

set -euxo pipefail

rendered_installer=${1:?usage: smoke-fedora-dkms-mok.sh <rendered-fedora-installer> <rendered-etc-installer>}
rendered_etc=${2:?usage: smoke-fedora-dkms-mok.sh <rendered-fedora-installer> <rendered-etc-installer>}
for f in "${rendered_installer}" "${rendered_etc}"; do
  if [[ ! -f "${f}" ]]; then
    printf 'missing rendered installer: %s\n' "${f}" >&2
    exit 1
  fi
done

scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-${HOME}/.cache}}
mkdir -p "${scratch_root}"
scratch=$(mktemp -d "${scratch_root}/fedora-dkms-mok.XXXXXX")
trap 'rm -rf "${scratch}"' EXIT
mkdir -p "${scratch}/bin"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# --- Structural contract: VirtualBox stays gone ------------------------------
#
# VirtualBox is no longer a managed package, so nothing in the installer may
# build, sign, or load its modules. Comment mentions are allowed (the group and
# manifest notes explain the removal); executable references are not.

if grep -Eq '^[^#]*(vboxconfig|vboxdrv|vboxusers|VirtualBox-)' "${rendered_installer}"; then
  fail 'VirtualBox was removed from the managed package set; the installer must not act on it'
fi
if grep -Eq '^[^#]*shim-signed' "${rendered_installer}"; then
  fail 'the shim-signed key paths existed only for Oracle vboxdrv.sh; they must not be provisioned'
fi

# The retired kernel-install hook must stay retired, in both directions: never
# re-invoked, and never re-implemented as a hand-rolled sign-file loop.
if grep -q 'install.d/50-vbox-sign' "${rendered_installer}" &&
   ! grep -q '^#.*50-vbox-sign' "${rendered_installer}"; then
  fail 'the retired 50-vbox-sign hook must not be invoked by the Fedora installer'
fi
if grep -Fq 'KERN_VER=' "${rendered_installer}"; then
  fail 'KERN_VER targeted a non-running kernel for the retired signing hook; it must not come back'
fi
if grep -Eq '/lib/modules/[^"]*/updates' "${rendered_installer}"; then
  fail 'the retired hook scanned /lib/modules/<ver>/updates; the installer must not scan it'
fi
if grep -Eq '^[^#]*sign-file' "${rendered_installer}"; then
  fail 'module signing belongs to DKMS; the installer must not run sign-file itself'
fi

# The hook must be absent from the /etc deploy list and present in its removals.
if grep -Eq '^ETC_(FILES|PATHS|SOURCES).*50-vbox-sign' "${rendered_etc}"; then
  fail 'the retired 50-vbox-sign hook must no longer be deployed to /etc'
fi
grep -Eq 'REMOVED_(ETC_)?PATHS\+=\(?"/etc/kernel/install\.d/50-vbox-sign\.install"\)?' "${rendered_etc}" ||
  fail 'the retired 50-vbox-sign hook must be listed for removal from /etc'

# --- Behavioral: the MOK keypair is never destroyed -------------------------
#
# Regression guard for a latent bug that DID destroy a live host's trust anchor.
# /var/lib/dkms is root-only, so the keypair is probed through sudo. When that
# sudo fails to authenticate, a `sudo test -f a && sudo test -f b` chain returns
# non-zero exactly as it does when the key is absent — and the caller then mints
# a fresh keypair over the enrolled one, stranding the enrolled certificate
# without its private key and breaking the NVIDIA DKMS driver until a new
# enrollment and reboot. The probe must therefore distinguish
# "cannot look" from "not there".

state_start=$(grep -n '^dkms_mok_state() {$' "${rendered_installer}" | cut -d: -f1 || true)
ensure_start=$(grep -n '^ensure_dkms_mok_generated() {$' "${rendered_installer}" | cut -d: -f1 || true)
cert_start=$(grep -n '^mok_cert_path() {$' "${rendered_installer}" | cut -d: -f1 || true)
key_start=$(grep -n '^mok_key_path() {$' "${rendered_installer}" | cut -d: -f1 || true)
if [[ -z "${state_start}" || -z "${ensure_start}" ]]; then
  fail 'rendered Fedora installer is missing the DKMS MOK state helpers'
fi
# The certificate path follows the resolved branch's module build system, so
# dkms_mok_state no longer names a literal path -- it asks these two helpers.
# Extract them alongside it, and leave nvidia_build_system unset so they answer
# with the DKMS pair this fixture drives.
if [[ -z "${cert_start}" || -z "${key_start}" ]]; then
  fail 'rendered Fedora installer is missing the branch-aware MOK path helpers'
fi
marker_start=$(grep -n '^cert_path_for_marker() {$' "${rendered_installer}" | cut -d: -f1 || true)
stale_start=$(grep -n '^report_stale_mok() {$' "${rendered_installer}" | cut -d: -f1 || true)
typeable_start=$(grep -n '^mok_passphrase_is_typeable() {$' "${rendered_installer}" | cut -d: -f1 || true)
manual_start=$(grep -n '^report_manual_mok_import() {$' "${rendered_installer}" | cut -d: -f1 || true)
for var in marker_start stale_start typeable_start manual_start; do
  [[ -n "${!var}" ]] || fail "rendered Fedora installer is missing the helper behind ${var}"
done

awaiting_start=$(grep -n '^report_awaiting_builder_key() {$' "${rendered_installer}" | cut -d: -f1 || true)
[[ -n "${awaiting_start}" ]] || fail 'rendered Fedora installer is missing report_awaiting_builder_key'

# The real reporting and predicate helpers, not stubs. Each is a printf or a
# grep -- no host state, no privilege -- and stubbing them would hide exactly the
# branches this harness exists to cover.
{
  sed -n "${marker_start},/^}$/p" "${rendered_installer}"
  sed -n "${stale_start},/^}$/p" "${rendered_installer}"
  sed -n "${typeable_start},/^}$/p" "${rendered_installer}"
  sed -n "${manual_start},/^}$/p" "${rendered_installer}"
  sed -n "${awaiting_start},/^}$/p" "${rendered_installer}"
} > "${scratch}/helpers.sh"

# $1 = build system. The paths follow the RESOLVED branch, so the fixture seeds
# nvidia_build_system and the two path helpers answer for that branch.
write_mok_paths() {
  {
    printf 'nvidia_build_system=%s\n' "$1"
    sed -n "${cert_start},/^}$/p" "${rendered_installer}"
    sed -n "${key_start},/^}$/p" "${rendered_installer}"
  } > "${scratch}/mok_paths.sh"
  cat "${scratch}/mok_paths.sh" > "${scratch}/mok_state.sh"
  sed -n "${state_start},/^}$/p" "${rendered_installer}" >> "${scratch}/mok_state.sh"
  # The awaiting-builder report is real for the akmod branch: its skip sits inside
  # that call's condition, so stubbing it would hide the branch under test. It is
  # a printf to stderr and always succeeds, so it is safe to run here.
  {
    cat "${scratch}/mok_paths.sh"
    cat "${scratch}/helpers.sh"
    sed -n "${ensure_start},/^}$/p" "${rendered_installer}"
  } > "${scratch}/mok_ensure.sh"
}

# BOTH trees are relocated. The akmods rewrite is what the previous version
# lacked: without it an akmod fixture would probe the host's real
# /etc/pki/akmods and read a CI runner's empty tree as the branch's answer.
relocate() {
  sed -e "s|'/var/lib/dkms/\([a-z.]*\)'|\"\${MOK_DIR}/\1\"|g" \
      -e 's|/var/lib/dkms|${MOK_DIR}|g' \
      -e "s|'/etc/pki/akmods/\([a-z/_.]*\)'|\"\${MOK_DIR}/akmods/\1\"|g" \
      -e 's|/etc/pki/akmods|${MOK_DIR}/akmods|g' \
      "$@"
}

write_mok_paths "${SMOKE_BUILD_SYSTEM:-dkms}"

# The always-succeeds sudo stub both enrollment fixtures drive. The state and mint
# fixtures need their own ok/fail/flaky variant -- the failed-probe regression is
# the whole point there -- so only these two are pooled.
plain_sudo_stub="${scratch}/plain-sudo.sh"
cat > "${plain_sudo_stub}" <<'STUB'
fake_sudo() {
  local -a a=()
  for x in "$@"; do a+=("${x/\/var\/lib\/dkms/${MOK_DIR}}"); done
  "${a[@]}"
}
SUDO=(fake_sudo)
STUB

# ensure_dkms_mok_generated must not re-probe the files itself, and the sole
# mint must be reachable only from the `absent` branch.
if grep -Eq 'test -f .*mok\.(pub|key)' "${scratch}/mok_ensure.sh"; then
  fail 'the MOK check must go through dkms_mok_state, not a sudo test -f chain that conflates sudo failure with a missing key'
fi
grep -Fq 'partial' "${scratch}/mok_ensure.sh" ||
  fail 'a half-present keypair must be refused, not overwritten'
# The mint must be confirmed by a re-probe, not by the minting tool's exit
# status: `mok_signing_setup` and `openssl` can both fail while leaving the
# function believing a keypair exists. Count only code, never comment mentions.
grep -v '^[[:space:]]*#' "${scratch}/mok_ensure.sh" > "${scratch}/mok_ensure.code"
mint_line=$(grep -n 'openssl req' "${scratch}/mok_ensure.code" | cut -d: -f1 || true)
reprobe_line=$(grep -n 'dkms_mok_state' "${scratch}/mok_ensure.code" | tail -1 | cut -d: -f1 || true)
if [[ -z "${mint_line}" || -z "${reprobe_line}" ]]; then
  fail 'ensure_dkms_mok_generated must both mint a keypair and probe for one'
fi
if (( reprobe_line <= mint_line )); then
  fail 'ensure_dkms_mok_generated must re-probe AFTER minting instead of trusting the tool exit status'
fi

mokdir=${scratch}/mokstate
mkdir -p "${mokdir}"
# $1 = sudo stub behavior: ok | fail
run_mok_state() {
  env MOK_SUDO="${1}" MOK_DIR="${mokdir}" bash -c '
    set -euo pipefail
    # Relocate the root-only paths and model sudo success/failure.
    fake_sudo() {
      [[ "${MOK_SUDO}" == ok ]] || return 1
      local -a a=()
      for x in "$@"; do a+=("${x/\/var\/lib\/dkms/${MOK_DIR}}"); done
      "${a[@]}"
    }
    SUDO=(fake_sudo)
    '"$(relocate "${scratch}/mok_state.sh")"'
    dkms_mok_state
  '
}

rm -f "${mokdir}"/mok.*
[[ "$(run_mok_state ok)" == absent ]] || fail 'an empty /var/lib/dkms must report absent'
printf cert > "${mokdir}/mok.pub"
[[ "$(run_mok_state ok)" == partial ]] || fail 'a certificate without its key must report partial'
printf key > "${mokdir}/mok.key"
[[ "$(run_mok_state ok)" == present ]] || fail 'a complete keypair must report present'

# The load-bearing case: sudo cannot run. The probe must FAIL, never say absent.
if out=$(run_mok_state fail 2>/dev/null); then
  fail 'dkms_mok_state must return non-zero when the privileged probe cannot run'
fi
if [[ "${out:-}" == absent ]]; then
  fail 'a failed sudo probe must never be reported as absent — that is what overwrites the enrolled MOK'
fi

# The environment guards are asserted structurally, not behaviorally: `[[ -d
# /sys/firmware/efi ]]` reads an absolute path that cannot be relocated, and a
# runner where it is absent would make the whole block vacuously pass. Each
# guard is a declared not-applicable skip spanning a block — the bare
# `|| return 0` one-liners it replaced are the silent no-op the declaration
# contract removed — so assert the whole block: its predicate opens it, a
# declaration sentinel names the site, and a `return 0` leaves the function.
# Then strip the block so the branch logic below runs deterministically.
#
# $1 = sed address matching the guard's opening line, $2 = what it guards.
assert_guard() {
  local block
  block=$(sed -n "${1},/^  fi\$/p" "${scratch}/mok_ensure.sh")
  [[ -n "${block}" ]] || fail "ensure_dkms_mok_generated must skip ${2}"
  grep -Fq 'skip-declaration-v1' <<<"${block}" ||
    fail "ensure_dkms_mok_generated must declare the skip it takes ${2}, not exit silently"
  grep -qx '    return 0' <<<"${block}" ||
    fail "ensure_dkms_mok_generated must leave the function when it skips ${2}"
}

efi_guard='/^  if \[\[ ! -d \/sys\/firmware\/efi \]\]; then$/'
secureboot_guard="/^  if ! mokutil --sb-state .*'SecureBoot enabled'; then\$/"
assert_guard "${efi_guard}" 'on a non-UEFI host'
assert_guard "${secureboot_guard}" 'when Secure Boot is off'

sed -e "${efi_guard},/^  fi\$/d" -e "${secureboot_guard},/^  fi\$/d" \
  "${scratch}/mok_ensure.sh" > "${scratch}/mok_ensure_nogates.sh"

# $1 = sudo behavior (ok|fail|flaky), $2 = openssl behavior (mint|noop).
# `flaky` models the real incident: a mistyped sudo password fails the FIRST
# privileged call, and the retry the user gets right succeeds — so the probe
# fails while the mint that follows it works.
# Returns ensure_dkms_mok_generated's exit status; prints CONTINUED on success.
# HOME is redirected into the scratch tree because the declared skips this
# function now takes clear their own state entry under $XDG_STATE_HOME, and a
# smoke test must not delete the caller's real skip records.
run_ensure() {
  rm -f "${mokdir}/.sudo_calls"
  env HOME="${scratch}/home" MOK_DIR="${mokdir}" MOK_SUDO="${1}" MOK_MINT="${2}" bash -c '
    set -uo pipefail
    fake_sudo() {
      case "${MOK_SUDO}" in
        ok) ;;
        fail) return 1 ;;
        flaky)
          local n
          n=$(cat "${MOK_DIR}/.sudo_calls" 2>/dev/null || printf 0)
          printf %s "$((n + 1))" > "${MOK_DIR}/.sudo_calls"
          [[ "${n}" -ge 1 ]] || return 1
          ;;
      esac
      local -a a=()
      for x in "$@"; do a+=("${x/\/var\/lib\/dkms/${MOK_DIR}}"); done
      "${a[@]}"
    }
    SUDO=(fake_sudo)
    openssl() {
      [[ "${MOK_MINT}" == mint ]] || return 1
      printf MINTED > "${MOK_DIR}/mok.pub"
      printf MINTED > "${MOK_DIR}/mok.key"
    }
    '"$(relocate "${scratch}/mok_state.sh" "${scratch}/mok_ensure_nogates.sh")"'
    ensure_dkms_mok_generated && printf CONTINUED
  ' 2>/dev/null
}

# THE regression case, in the exact shape it happened: the probe cannot run, but
# the very next privileged call can. A conflating probe reads that as "absent"
# and mints over the enrolled keypair. Must refuse, leaving both files intact.
before_pub=$(cat "${mokdir}/mok.pub"); before_key=$(cat "${mokdir}/mok.key")
if [[ "$(run_ensure flaky mint)" == *CONTINUED* ]]; then
  fail 'a probe that failed must not be read as "absent" — that is what overwrote a live enrolled MOK'
fi
[[ "$(cat "${mokdir}/mok.pub")" == "${before_pub}" && "$(cat "${mokdir}/mok.key")" == "${before_key}" ]] ||
  fail 'a failed probe followed by a working sudo must never mint over the existing MOK keypair'

# Same contract when sudo is down for the whole run.
if [[ "$(run_ensure fail mint)" == *CONTINUED* ]]; then
  fail 'ensure_dkms_mok_generated must not report success when it could not read the keypair'
fi
[[ "$(cat "${mokdir}/mok.pub")" == "${before_pub}" && "$(cat "${mokdir}/mok.key")" == "${before_key}" ]] ||
  fail 'an unreadable probe must never mint over the existing MOK keypair'

# A half-present keypair must also be refused, with the surviving half intact.
rm -f "${mokdir}/mok.key"
if [[ "$(run_ensure ok mint)" == *CONTINUED* ]]; then
  fail 'a half-present keypair must be refused, not completed by a fresh mint'
fi
[[ "$(cat "${mokdir}/mok.pub")" == "${before_pub}" ]] ||
  fail 'refusing a half-present keypair must leave the existing certificate intact'
[[ ! -e "${mokdir}/mok.key" ]] ||
  fail 'refusing a half-present keypair must not create the missing half'

# A complete keypair is accepted untouched — no mint, no rewrite.
printf key > "${mokdir}/mok.key"
[[ "$(run_ensure ok noop)" == *CONTINUED* ]] ||
  fail 'a complete keypair must be accepted'
[[ "$(cat "${mokdir}/mok.pub")" == "${before_pub}" ]] ||
  fail 'an existing complete keypair must never be rewritten'

# A genuinely absent keypair IS minted, and the mint is confirmed.
rm -f "${mokdir}"/mok.*
[[ "$(run_ensure ok mint)" == *CONTINUED* ]] ||
  fail 'an absent keypair must be minted'
[[ "$(cat "${mokdir}/mok.pub")" == MINTED ]] ||
  fail 'the mint must actually write the keypair'

# A mint that silently fails must be caught by the post-mint re-probe.
rm -f "${mokdir}"/mok.*
if [[ "$(run_ensure ok noop)" == *CONTINUED* ]]; then
  fail 'a failed mint must be caught by the post-mint re-probe, not reported as success'
fi

# --- Both build systems ------------------------------------------------------
#
# The legacy branch builds through akmods, which mints its OWN keypair with
# kmodgenca on the first module build. So the installer must NOT mint one for it:
# a key minted here would sign the module with a key the builder does not use.
# The declared wait is what makes that visible, and it is transient-blocking, so
# the host re-runs itself once the key appears.
write_mok_paths akmod

akmod_cert=$(env MOK_DIR="${mokdir}" bash -c '
  set -uo pipefail
  '"$(relocate "${scratch}/mok_paths.sh")"'
  mok_cert_path
')
[[ "${akmod_cert}" == "${mokdir}/akmods/certs/public_key.der" ]] ||
  fail "the akmod branch must resolve to the akmods certificate, got ${akmod_cert}"

akmod_key=$(env MOK_DIR="${mokdir}" bash -c '
  set -uo pipefail
  '"$(relocate "${scratch}/mok_paths.sh")"'
  mok_key_path
')
[[ "${akmod_key}" == "${mokdir}/akmods/private/private_key.priv" ]] ||
  fail "the akmod branch must resolve to the akmods private key, got ${akmod_key}"

# The state probe over the akmods tree. Relocated the same way the DKMS one is;
# without the akmods rewrite this would read the runner's real /etc/pki/akmods.
mkdir -p "${mokdir}/akmods/certs" "${mokdir}/akmods/private"
rm -f "${mokdir}/akmods/certs/public_key.der" "${mokdir}/akmods/private/private_key.priv"
[[ "$(run_mok_state ok)" == absent ]] ||
  fail 'an empty akmods tree must report absent'
printf cert > "${mokdir}/akmods/certs/public_key.der"
[[ "$(run_mok_state ok)" == partial ]] ||
  fail 'an akmods certificate without its key must report partial'
printf key > "${mokdir}/akmods/private/private_key.priv"
[[ "$(run_mok_state ok)" == present ]] ||
  fail 'a complete akmods keypair must report present'

# THE ASSERTION THE PINNED DKMS DEFAULT MADE UNREACHABLE: on the akmod branch with
# no builder key yet, ensure_dkms_mok_generated declares the wait and returns
# WITHOUT reaching the openssl mint.
sed -e "${efi_guard},/^  fi\$/d" -e "${secureboot_guard},/^  fi\$/d" \
  "${scratch}/mok_ensure.sh" > "${scratch}/mok_ensure_nogates.sh"
grep -Fq 'mok-generate-awaiting-builder' "${scratch}/mok_ensure_nogates.sh" ||
  fail 'ensure_dkms_mok_generated does not declare the awaiting-builder wait'

rm -f "${mokdir}/akmods/certs/public_key.der" "${mokdir}/akmods/private/private_key.priv"
skip_record="${scratch}/home/.local/state/chezmoi/skips/install-nvidia-fedora__mok-generate-awaiting-builder"
rm -f "${skip_record}"
run_ensure ok mint >/dev/null
# The state record, not the return value: skip_step deliberately returns 0 so the
# caller keeps running, so the record is what distinguishes taking the wait from
# falling through it. dotfiles-skips reads this same file.
[[ -f "${skip_record}" ]] ||
  fail 'the akmod branch did not record the awaiting-builder wait; it fell through instead'
grep -Fq 'transient-blocking:akmods-signing-key-present' "${skip_record}" ||
  fail 'the awaiting-builder wait is not recorded against its capability probe'
if [[ -e "${mokdir}/akmods/certs/public_key.der" || -e "${mokdir}/mok.pub" ]]; then
  fail 'the akmod branch must never mint a keypair; the module builder owns that key'
fi

# Once the builder HAS minted its pair, the same call accepts it untouched.
printf builder-cert > "${mokdir}/akmods/certs/public_key.der"
printf builder-key > "${mokdir}/akmods/private/private_key.priv"
[[ "$(run_ensure ok noop)" == *CONTINUED* ]] ||
  fail 'a complete akmods keypair must be accepted'
[[ "$(cat "${mokdir}/akmods/certs/public_key.der")" == builder-cert ]] ||
  fail 'an existing akmods certificate must never be rewritten'

# --- cert_path_for_marker ----------------------------------------------------
#
# Each branch marker resolves to ITS OWN build system's certificate, which is what
# lets report_stale_mok name a certificate enrolled for a branch this host no
# longer resolves to. Nothing asserted this before.
marker_cert() {
  env MOK_DIR="${mokdir}" MARKER="$1" bash -c '
    set -uo pipefail
    '"$(relocate "${scratch}/mok_paths.sh" "${scratch}/helpers.sh")"'
    if out=$(cert_path_for_marker "$MARKER"); then printf "%s" "$out"; else printf "unmapped"; fi
  '
}
[[ "$(marker_cert akmod-nvidia-580xx)" == "${mokdir}/akmods/certs/public_key.der" ]] ||
  fail 'the akmod branch marker does not resolve to the akmods certificate'
[[ "$(marker_cert kmod-nvidia-latest-dkms)" == "${mokdir}/mok.pub" ]] ||
  fail 'the DKMS branch marker does not resolve to the DKMS certificate'
[[ "$(marker_cert some-unrelated-package)" == unmapped ]] ||
  fail 'an unknown marker must not resolve to a certificate'

write_mok_paths dkms

# --- Structural contract: enrollment seeds, then re-probes -------------------
#
# ensure_dkms_mok_generated used to be reached only from the VirtualBox signing
# path. With that path gone, enrollment is its sole caller, and the wiring has
# to keep two properties: seeding is attempted only where a module actually
# needs signing, and its outcome is never trusted directly — the state probe
# decides, so a failed mint cannot enroll a key that is not there.

enroll_start=$(grep -n '^enroll_dkms_mok() {$' "${rendered_installer}" | cut -d: -f1 || true)
[[ -n "${enroll_start}" ]] || fail 'rendered Fedora installer is missing enroll_dkms_mok'
sed -n "${enroll_start},/^}$/p" "${rendered_installer}" > "${scratch}/enroll.sh"

grep -Fq 'ensure_dkms_mok_generated' "${scratch}/enroll.sh" ||
  fail 'enrollment must seed the DKMS MOK; nothing else calls ensure_dkms_mok_generated now'

grep -v '^[[:space:]]*#' "${scratch}/enroll.sh" > "${scratch}/enroll.code"
seed_line=$(grep -n 'ensure_dkms_mok_generated' "${scratch}/enroll.code" | head -1 | cut -d: -f1 || true)
probe_line=$(grep -n 'dkms_mok_state' "${scratch}/enroll.code" | head -1 | cut -d: -f1 || true)
if [[ -z "${seed_line}" || -z "${probe_line}" ]]; then
  fail 'enroll_dkms_mok must seed the keypair and then probe for it'
fi
if (( probe_line <= seed_line )); then
  fail 'enroll_dkms_mok must probe AFTER seeding, so a failed mint cannot reach mokutil --import'
fi
grep -Eq 'mok_state}" (!=|==) present' "${scratch}/enroll.code" ||
  fail 'only a complete keypair may be enrolled; partial and unreadable must not reach mokutil --import'
grep -Eq 'fp=.*openssl x509.*-fingerprint' "${scratch}/enroll.code" ||
  fail 'enroll_dkms_mok must compute certificate fingerprint before checking queued keys'

sed -e "${efi_guard},/^  fi\$/d" -e "${secureboot_guard},/^  fi\$/d" \
  "${scratch}/enroll.sh" > "${scratch}/enroll_nogates.sh"

run_enroll() {
  env HOME="${scratch}/home" MOK_DIR="${mokdir}" PLAIN_SUDO_STUB="${plain_sudo_stub}" \
    MOK_TEST_KEY="${1}" MOK_LIST_NEW="${2}" bash -c '
    set -uo pipefail
    . "${PLAIN_SUDO_STUB:?}"
    mokutil() {
      case "${1-}" in
        --test-key)
          [[ "${MOK_TEST_KEY}" == enrolled ]] && printf "%s is already enrolled\n" "${2-}"
          return 0
          ;;
        --list-new)
          [[ "${MOK_LIST_NEW}" == queued ]] && printf "[key 1]\nSHA1 Fingerprint: 11:22:33:44:55:66:77:88:99:00:aa:bb:cc:dd:ee:ff:00:11:22:33\n"
          return 0
          ;;
        --import)
          return 0
          ;;
      esac
      return 1
    }
    ensure_dkms_mok_generated() { return 0; }
    '"$(relocate "${scratch}/mok_state.sh" "${scratch}/helpers.sh" "${scratch}/enroll_nogates.sh")"'
    enroll_dkms_mok && printf CONTINUED
  ' 2>/dev/null
}

printf cert > "${mokdir}/mok.pub"
printf key > "${mokdir}/mok.key"

[[ "$(run_enroll enrolled none)" == *CONTINUED* ]] ||
  fail 'enroll_dkms_mok must succeed when key is already enrolled'
[[ "$(run_enroll not_enrolled queued)" == *CONTINUED* ]] ||
  fail 'enroll_dkms_mok must succeed when key is already queued'
[[ "$(run_enroll not_enrolled not_queued)" == *CONTINUED* ]] ||
  fail 'enroll_dkms_mok must succeed when importing a new key'
# --- Non-interactive enrollment ---------------------------------------------
#
# `mokutil --import` reads a one-time enrollment password from the terminal, so on
# a non-interactive apply it fails -- and the call used to end in
# `2>/dev/null || true`, which discarded both the error text and the exit status.
# The apply reported success, no MokNew variable was written, and Secure Boot then
# rejected the signed module with nothing on screen to say why.
#
# The password is the stored LUKS passphrase, handed to expect through the
# ENVIRONMENT. Two properties are load-bearing and asserted here: the passphrase
# never reaches an argument vector, and the import's exit status is propagated.

# The rendered assignment: base64 for shell safety, and exactly one of them.
assign_line=$(grep -c 'MOK_ENROLL_PASSPHRASE="\$(printf .%s. .* | base64 -d)"' "${scratch}/enroll.code" || true)
[[ "${assign_line}" == 1 ]] ||
  fail 'the enrollment passphrase is not assigned through the single base64 form the LUKS wrapper uses'

# ARGV IS THE PROPERTY. `sudo env VAR=...` would put the passphrase in env's own
# argument vector, readable in the process table by every user on the box. The
# rendered call must therefore pass it as an ENVIRONMENT PREFIX to an
# unprivileged expect, which spawns the elevation itself.
grep -Fq 'MOK_ENROLL_PASSPHRASE="$MOK_ENROLL_PASSPHRASE" MOK_CERT="$cert"' "${scratch}/enroll.code" ||
  fail 'the enrollment passphrase is not handed to expect as an environment prefix'
if grep -Eq 'env[[:space:]]+MOK_ENROLL_PASSPHRASE=' "${scratch}/enroll.code"; then
  fail 'the passphrase must never reach an argument vector; `sudo env VAR=...` exposes it in the process table'
fi
if grep -Eq 'mokutil --import.*(\|\| true|2>/dev/null \|\| true)' "${scratch}/enroll.code"; then
  fail 'the mokutil --import exit status must be propagated, never discarded'
fi

# The expect script's own hardening. All three prevent a HUNG apply or a re-parse
# of interpolated data rather than a wrong answer, and all three are read from the
# comment-stripped copy: this installer explains the shapes it forbids, and a
# comment naming one must not read as the shape itself.
grep -Fq 'LC_ALL=C expect -f -' "${scratch}/enroll.code" ||
  fail 'the expect call is not pinned to LC_ALL=C, so a localized mokutil prompt would not match'
if grep -Fq 'eval spawn' "${scratch}/enroll.code"; then
  fail 'spawn must expand the argument list with {*}, not re-parse it through eval'
fi
grep -Fq 'spawn -noecho {*}$argv' "${scratch}/enroll.code" ||
  fail 'the expect script does not spawn through a {*}-expanded argument list'
[[ $(grep -c '^    timeout {' "${scratch}/enroll.code") -ge 3 ]] ||
  fail 'every expect block needs a timeout action; without one an unmatched prompt blocks in wait and hangs the apply'

# The extraction contract this heredoc has to respect: every helper is pulled out
# with `sed -n '<start>,/^}$/p'`, so a `}` at column 0 inside the heredoc would
# truncate enroll_dkms_mok at that brace and this harness would drive half a
# function. Assert the whole function arrived.
grep -Fq 'is queued for enrollment' "${scratch}/enroll.sh" ||
  fail 'enroll_dkms_mok was extracted truncated; a line that is exactly } at column 0 inside the expect heredoc ends the extraction early'

# A PATH with only what the enrollment body reaches, so `command -v expect` is
# decided by this fixture and not by whatever the runner happens to have.
minbin="${scratch}/minbin"
mkdir -p "${minbin}"
# bash is here for the expect STUB's own shebang, not for the code under test;
# everything else is a tool the enrollment body actually reaches.
for tool in grep base64 sh sed mkdir rm openssl cat bash; do
  real=$(command -v "${tool}") || fail "the fixture needs ${tool} on PATH"
  ln -sf "${real}" "${minbin}/${tool}"
done

# Records the whole call surface -- argv, the two environment variables, and the
# expect script it is fed on stdin -- using only bash builtins, because the
# fixture PATH deliberately carries almost nothing.
cat > "${scratch}/expect-stub" <<'STUB'
#!/usr/bin/env bash
script=$(cat)
{
  printf 'argv:'
  printf ' %s' "$@"
  printf '\n'
  if [[ -n "${MOK_ENROLL_PASSPHRASE-}" ]]; then
    printf 'env-passphrase:%s\n' "${MOK_ENROLL_PASSPHRASE}"
  fi
  printf 'env-cert:%s\n' "${MOK_CERT-}"
  printf 'stdin-bytes:%s\n' "${#script}"
} >> "${EXPECT_LOG:?}"
exit "${EXPECT_RC:-0}"
STUB
chmod 0755 "${scratch}/expect-stub"

# $1 = passphrase to render in, $2 = have-expect (yes|no), $3 = expect exit code.
# Prints CONTINUED when enroll_dkms_mok succeeded; $EXPECT_LOG records the call.
run_enroll_import() {
  local passphrase=$1 have_expect=$2 expect_rc=$3
  rm -rf -- "${scratch}/enroll-home"
  rm -f -- "${minbin}/expect"
  mkdir -p "${scratch}/enroll-home"
  : > "${scratch}/expect.log"
  [[ "${have_expect}" == yes ]] && ln -sf "${scratch}/expect-stub" "${minbin}/expect"
  # The one fixture rewrite: the rendered assignment is a literal, so drive it
  # from the environment instead. Its shape was asserted above.
  sed -E 's|MOK_ENROLL_PASSPHRASE="\$\(printf .%s. .*\| base64 -d\)"|MOK_ENROLL_PASSPHRASE="${SMOKE_MOK_PASSPHRASE-}"|' \
    "${scratch}/enroll_nogates.sh" > "${scratch}/enroll_import.sh"
  grep -Fq 'MOK_ENROLL_PASSPHRASE="${SMOKE_MOK_PASSPHRASE-}"' "${scratch}/enroll_import.sh" ||
    fail 'the fixture could not redirect the rendered passphrase assignment'
  env -i HOME="${scratch}/enroll-home" PATH="${minbin}" \
    MOK_DIR="${mokdir}" PLAIN_SUDO_STUB="${plain_sudo_stub}" SMOKE_MOK_PASSPHRASE="${passphrase}" \
    EXPECT_LOG="${scratch}/expect.log" EXPECT_RC="${expect_rc}" \
    "${BASH}" -c '
      set -uo pipefail
      . "${PLAIN_SUDO_STUB:?}"
      mokutil() {
        case "${1-}" in
          --test-key) return 0 ;;
          --list-new) return 0 ;;
        esac
        return 1
      }
      ensure_dkms_mok_generated() { return 0; }
      '"$(relocate "${scratch}/mok_state.sh" "${scratch}/helpers.sh" "${scratch}/enroll_import.sh")"'
      enroll_dkms_mok && printf CONTINUED
    ' 2>"${scratch}/enroll.err"
}

skips="${scratch}/enroll-home/.local/state/chezmoi/skips"
printf cert > "${mokdir}/mok.pub"
printf key > "${mokdir}/mok.key"

# A `harmless` skip DELETES its state entry -- nothing is outstanding -- so its
# signal is the operator notice on stdout. Only a record-keeping direction leaves
# a file behind, which is what the absent-expect case asserts below.
no_passphrase_out=$(run_enroll_import '' yes 0)
grep -Fq 'no stored passphrase is available' <<<"${no_passphrase_out}" ||
  fail "an absent enrollment passphrase did not take its declared skip; output was: ${no_passphrase_out}"
grep -Fq 'sudo mokutil --import' "${scratch}/enroll.err" ||
  fail 'an absent passphrase did not print the by-hand mokutil command'
[[ ! -s "${scratch}/expect.log" ]] ||
  fail 'an absent passphrase still invoked expect'

# expect absent: transient-blocking, so it KEEPS its record and self-heals once
# the base package set installs expect.
no_expect_out=$(run_enroll_import 'fixture-passphrase' no 0)
[[ -f "${skips}/install-nvidia-fedora__mok-enroll-no-expect" ]] ||
  fail "an absent expect did not record its declared skip; output was: ${no_expect_out}"
grep -Fq 'transient-blocking:expect-present' "${skips}/install-nvidia-fedora__mok-enroll-no-expect" ||
  fail 'the absent-expect skip is not recorded against its capability probe'
grep -Fq 'sudo mokutil --import' "${scratch}/enroll.err" ||
  fail 'an absent expect did not print the by-hand mokutil command'

# A passphrase MokManager cannot accept: it reads on a US-layout UEFI console, so
# a non-ASCII byte is untypeable there and queueing the request would reboot the
# host into a prompt it can never satisfy.
untypeable_out=$(run_enroll_import 'pässphrase' yes 0)
grep -Fq 'not printable US-ASCII' <<<"${untypeable_out}" ||
  fail "a non-ASCII passphrase did not take its declared skip; output was: ${untypeable_out}"
[[ ! -s "${scratch}/expect.log" ]] ||
  fail 'a passphrase that cannot be typed at MokManager still queued a request'

# The happy path: expect is driven, and the passphrase arrives in its ENVIRONMENT
# while its argument vector carries only the script flags.
[[ "$(run_enroll_import 'fixture-passphrase' yes 0)" == *CONTINUED* ]] ||
  fail 'a typeable passphrase with expect present did not complete the import'
grep -Fq 'env-passphrase:fixture-passphrase' "${scratch}/expect.log" ||
  fail 'the passphrase did not reach expect through the environment'
grep -Fq 'env-cert:' "${scratch}/expect.log" ||
  fail 'the certificate path did not reach expect through the environment'
if grep -F 'argv:' "${scratch}/expect.log" | grep -Fq 'fixture-passphrase'; then
  fail 'the passphrase reached expect through its ARGUMENT VECTOR, readable in the process table'
fi
grep -Eq '^stdin-bytes:[1-9][0-9]*$' "${scratch}/expect.log" ||
  fail 'the expect script was not fed on stdin'

# A failing import fails the function loudly and says what to run by hand. This is
# the whole defect the discarded `|| true` created.
if [[ "$(run_enroll_import 'fixture-passphrase' yes 3)" == *CONTINUED* ]]; then
  fail 'a failed mokutil --import must not be reported as success'
fi
grep -Fq 'the certificate was NOT queued' "${scratch}/enroll.err" ||
  fail 'a failed import did not say the certificate was not queued'
grep -Fq 'sudo mokutil --import' "${scratch}/enroll.err" ||
  fail 'a failed import did not print the by-hand mokutil command'

printf 'Fedora DKMS MOK smoke passed.\n'
