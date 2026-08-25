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
grep -Fq 'REMOVED_ETC_PATHS+=("/etc/kernel/install.d/50-vbox-sign.install")' "${rendered_etc}" ||
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
if [[ -z "${state_start}" || -z "${ensure_start}" ]]; then
  fail 'rendered Fedora installer is missing the DKMS MOK state helpers'
fi
sed -n "${state_start},/^}$/p" "${rendered_installer}" > "${scratch}/mok_state.sh"
sed -n "${ensure_start},/^}$/p" "${rendered_installer}" > "${scratch}/mok_ensure.sh"

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
    '"$(sed 's|/var/lib/dkms|${MOK_DIR}|g' "${scratch}/mok_state.sh")"'
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
    '"$(sed 's|/var/lib/dkms|${MOK_DIR}|g' "${scratch}/mok_state.sh" "${scratch}/mok_ensure_nogates.sh")"'
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
grep -Fq 'mok_state}" == present' "${scratch}/enroll.code" ||
  fail 'only a complete keypair may be enrolled; partial and unreadable must not reach mokutil --import'

printf 'Fedora DKMS MOK smoke passed.\n'
