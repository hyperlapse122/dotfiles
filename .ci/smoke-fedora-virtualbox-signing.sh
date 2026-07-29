#!/usr/bin/env bash

# Assert the Fedora VirtualBox Secure Boot signing contract against rendered
# provisioning output.
#
# The bug this guards: Oracle's vboxdrv.sh signs the modules it builds, but on
# Fedora it reads key material only from the Debian paths
# /var/lib/shim-signed/mok/MOK.{der,priv}. Without them its signing step calls
# `failure`, vboxdrv.service fails at every boot, and VirtualBox reports
# VERR_VM_DRIVER_NOT_INSTALLED. The Fedora installer must link those paths at
# the enrolled DKMS MOK, verify a signature actually landed, and load the driver
# — and must never revive the retired kernel-install hook, which scanned the
# wrong module directory and could not build for a non-running kernel.
#
# The key-linking and signature-detection helpers are executed for real against
# a scratch tree with stubbed `modinfo`; the guard ordering inside
# provision_vbox_module_signing is asserted as rendered text, because its
# `/sys/firmware/efi` and Secure Boot guards are not relocatable.

set -euo pipefail

rendered_installer=${1:?usage: smoke-fedora-virtualbox-signing.sh <rendered-fedora-installer> <rendered-etc-installer>}
rendered_etc=${2:?usage: smoke-fedora-virtualbox-signing.sh <rendered-fedora-installer> <rendered-etc-installer>}
for f in "${rendered_installer}" "${rendered_etc}"; do
  if [[ ! -f "${f}" ]]; then
    printf 'missing rendered installer: %s\n' "${f}" >&2
    exit 1
  fi
done

scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-${HOME}/.cache}}
mkdir -p "${scratch_root}"
scratch=$(mktemp -d "${scratch_root}/fedora-vbox-signing.XXXXXX")
trap 'rm -rf "${scratch}"' EXIT
mkdir -p "${scratch}/bin"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# --- Structural contract: the retired hook must stay retired -----------------

if grep -q 'install.d/50-vbox-sign' "${rendered_installer}" &&
   ! grep -q '^#.*50-vbox-sign' "${rendered_installer}"; then
  fail 'the retired 50-vbox-sign hook must not be invoked by the Fedora installer'
fi
if grep -Fq 'KERN_VER=' "${rendered_installer}"; then
  fail 'KERN_VER cannot target a non-running kernel; vboxdrv.sh overwrites it from uname -r'
fi
if grep -Eq '/lib/modules/[^"]*/updates' "${rendered_installer}"; then
  fail 'Oracle installs vbox modules to /lib/modules/<ver>/misc, never updates/'
fi
if grep -Eq '^[^#]*sign-file' "${rendered_installer}"; then
  fail 'signing is delegated to Oracle vboxdrv.sh; the installer must not run sign-file itself'
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
# without its private key and breaking VirtualBox and the NVIDIA DKMS driver
# until a new enrollment and reboot. The probe must therefore distinguish
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
run_mok_state() { # $1 = sudo stub behavior: ok | fail
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
# runner where it is absent would make the whole block vacuously pass. Confirm
# they exist, then strip them so the branch logic runs deterministically.
grep -Fq '[[ -d /sys/firmware/efi ]] || return 0' "${scratch}/mok_ensure.sh" ||
  fail 'ensure_dkms_mok_generated must skip on a non-UEFI host'
grep -Fq 'SecureBoot enabled' "${scratch}/mok_ensure.sh" ||
  fail 'ensure_dkms_mok_generated must skip when Secure Boot is off'

sed -e '/\[\[ -d \/sys\/firmware\/efi \]\]/d' -e '/SecureBoot enabled/d' \
  "${scratch}/mok_ensure.sh" > "${scratch}/mok_ensure_nogates.sh"

# $1 = sudo behavior (ok|fail|flaky), $2 = openssl behavior (mint|noop).
# `flaky` models the real incident: a mistyped sudo password fails the FIRST
# privileged call, and the retry the user gets right succeeds — so the probe
# fails while the mint that follows it works.
# Returns ensure_dkms_mok_generated's exit status; prints CONTINUED on success.
run_ensure() {
  rm -f "${mokdir}/.sudo_calls"
  env MOK_DIR="${mokdir}" MOK_SUDO="${1}" MOK_MINT="${2}" bash -c '
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

# --- Structural contract: guard order and no silent skips -------------------

fn_start=$(grep -n '^provision_vbox_module_signing() {$' "${rendered_installer}" | cut -d: -f1 || true)
[[ -n "${fn_start}" ]] || fail 'rendered Fedora installer is missing provision_vbox_module_signing'
sed -n "${fn_start},/^}$/p" "${rendered_installer}" > "${scratch}/provision.sh"

grep -Fq 'rpm -q VirtualBox-7.2' "${scratch}/provision.sh" ||
  fail 'signing must be a no-op when VirtualBox is not installed'
grep -Fq 'SecureBoot enabled' "${scratch}/provision.sh" ||
  fail 'signing must be a no-op when Secure Boot is off'
# The MOK result must gate the rest: proceeding past an unusable keypair lets
# Oracle sign against a key the firmware does not trust, which looks like
# success and still fails at modprobe.
grep -Fq 'ensure_dkms_mok_generated' "${scratch}/provision.sh" ||
  fail 'provisioning must ensure the DKMS MOK exists before linking it'
if grep -Eq '^[[:space:]]*ensure_dkms_mok_generated[[:space:]]*(\|\|[[:space:]]*true)?[[:space:]]*$' "${scratch}/provision.sh"; then
  fail 'the MOK result must be acted on; an unguarded call lets signing proceed with no usable key'
fi
# The module directory must be Oracle's fixed misc/ convention for the running
# kernel — not a depmod-index lookup that is briefly empty mid-rebuild, and
# never the updates/ directory the retired hook scanned.
grep -Fq 'module_dir="/lib/modules/$(uname -r)/misc"' "${scratch}/provision.sh" ||
  fail 'the signedness check must target /lib/modules/$(uname -r)/misc'
grep -Fq 'shim_dir=/var/lib/shim-signed/mok' "${scratch}/provision.sh" ||
  fail 'the installer must provision the shim-signed key paths vboxdrv.sh reads'
grep -Fq '"${shim_dir}/MOK.der"' "${scratch}/provision.sh" ||
  fail 'MOK.der must be linked from the shim-signed directory'
grep -Fq '"${shim_dir}/MOK.priv"' "${scratch}/provision.sh" ||
  fail 'MOK.priv must be linked from the shim-signed directory'
# KTD2/R5: the link targets are the one enrolled DKMS MOK, not a second keypair.
grep -Fq 'mok_pub=/var/lib/dkms/mok.pub' "${scratch}/provision.sh" ||
  fail 'the signing certificate must be the enrolled DKMS MOK at /var/lib/dkms/mok.pub'
grep -Fq 'mok_key=/var/lib/dkms/mok.key' "${scratch}/provision.sh" ||
  fail 'the signing key must be the enrolled DKMS MOK at /var/lib/dkms/mok.key'
grep -Fq 'link_vbox_signing_key "${mok_pub}" "${shim_dir}/MOK.der"' "${scratch}/provision.sh" ||
  fail 'MOK.der must be linked at the DKMS MOK certificate'
grep -Fq 'link_vbox_signing_key "${mok_key}" "${shim_dir}/MOK.priv"' "${scratch}/provision.sh" ||
  fail 'MOK.priv must be linked at the DKMS MOK private key'

# The build must be conditional on the modules being missing or unsigned, and a
# signature must be verified afterwards. Two vbox_modules_signed calls bracket
# the vboxconfig invocation.
if [[ $(grep -c 'vbox_modules_signed' "${scratch}/provision.sh") -ne 2 ]]; then
  fail 'vboxconfig must be gated on vbox_modules_signed and verified by it afterwards'
fi
guard_line=$(grep -n 'if vbox_modules_signed' "${scratch}/provision.sh" | cut -d: -f1 || true)
build_line=$(grep -n 'vboxconfig; then' "${scratch}/provision.sh" | cut -d: -f1 || true)
verify_line=$(grep -n 'if ! vbox_modules_signed' "${scratch}/provision.sh" | cut -d: -f1 || true)
if [[ -z "${guard_line}" || -z "${build_line}" || -z "${verify_line}" ]]; then
  fail 'provision_vbox_module_signing must guard, build, then verify'
fi
if (( guard_line >= build_line || build_line >= verify_line )); then
  fail 'the signature check must gate the build and then confirm it'
fi
# Both exits from the build gate must load the driver: the converged path and
# the path that just rebuilt and verified. Otherwise an apply can leave signed
# modules unloaded and VirtualBox still broken until reboot.
if [[ $(grep -c '^ *activate_vbox_driver$' "${scratch}/provision.sh") -ne 2 ]]; then
  fail 'the driver must be loaded on both the converged and the freshly-signed path'
fi
if grep -Eq 'vboxconfig[^|]*(2>/dev/null|>/dev/null 2>&1)' "${scratch}/provision.sh"; then
  fail 'vboxconfig output must not be discarded — a silent build failure is the bug being fixed'
fi

# --- Behavioral: link_vbox_signing_key --------------------------------------

link_start=$(grep -n '^link_vbox_signing_key() {$' "${rendered_installer}" | cut -d: -f1 || true)
signed_start=$(grep -n '^vbox_modules_signed() {$' "${rendered_installer}" | cut -d: -f1 || true)
if [[ -z "${link_start}" || -z "${signed_start}" ]]; then
  fail 'rendered Fedora installer is missing the signing helper functions'
fi
sed -n "${link_start},/^}$/p" "${rendered_installer}" > "${scratch}/link.sh"
sed -n "${signed_start},/^}$/p" "${rendered_installer}" > "${scratch}/signed.sh"

if grep -Eq '\bcp\b' "${scratch}/link.sh"; then
  fail 'the MOK must be symlinked, never copied — a copy duplicates a private key'
fi

fake=${scratch}/root
mkdir -p "${fake}/var/lib/dkms"
printf 'cert\n' > "${fake}/var/lib/dkms/mok.pub"
printf 'key\n' > "${fake}/var/lib/dkms/mok.key"
shim_dir=${fake}/var/lib/shim-signed/mok

run_link() {
  env FAKE_TARGET="$1" FAKE_LINK="$2" bash -c '
    set -euo pipefail
    SUDO=()
    '"$(cat "${scratch}/link.sh")"'
    link_vbox_signing_key "${FAKE_TARGET}" "${FAKE_LINK}"
  '
}

# Fresh host: the link is created and points at the DKMS MOK.
run_link "${fake}/var/lib/dkms/mok.pub" "${shim_dir}/MOK.der" ||
  fail 'linking the MOK on a fresh host must succeed'
[[ -L "${shim_dir}/MOK.der" ]] || fail 'MOK.der must be a symlink'
[[ "$(readlink "${shim_dir}/MOK.der")" == "${fake}/var/lib/dkms/mok.pub" ]] ||
  fail 'MOK.der must point at the DKMS MOK certificate'
[[ "$(stat -c '%a' "${shim_dir}")" == 700 ]] ||
  fail 'the shim-signed mok directory must be mode 0700'

# Converged host: a second run leaves the correct link untouched.
before=$(stat -c '%Y' "${shim_dir}/MOK.der" 2>/dev/null || stat -f '%m' "${shim_dir}/MOK.der")
run_link "${fake}/var/lib/dkms/mok.pub" "${shim_dir}/MOK.der" ||
  fail 'relinking an already-correct MOK must succeed'
after=$(stat -c '%Y' "${shim_dir}/MOK.der" 2>/dev/null || stat -f '%m' "${shim_dir}/MOK.der")
[[ "${before}" == "${after}" ]] || fail 'an already-correct link must not be rewritten'

# Drifted host: a link pointing elsewhere is repaired.
ln -sfn /nonexistent/stale.der "${shim_dir}/MOK.der"
run_link "${fake}/var/lib/dkms/mok.pub" "${shim_dir}/MOK.der" ||
  fail 'a stale link must be repaired'
[[ "$(readlink "${shim_dir}/MOK.der")" == "${fake}/var/lib/dkms/mok.pub" ]] ||
  fail 'a stale link must be repointed at the DKMS MOK'

# Foreign host state: a real file is never clobbered, and the caller is told.
printf 'someone-elses-key\n' > "${shim_dir}/MOK.priv"
if run_link "${fake}/var/lib/dkms/mok.key" "${shim_dir}/MOK.priv" 2>"${scratch}/warn.log"; then
  fail 'an existing regular key file must make the helper fail rather than clobber it'
fi
[[ "$(cat "${shim_dir}/MOK.priv")" == 'someone-elses-key' ]] ||
  fail 'an existing regular key file must be left byte-for-byte intact'
grep -Fq 'already exists as a regular file' "${scratch}/warn.log" ||
  fail 'refusing to clobber an existing key must emit an actionable warning'

# --- Behavioral: vbox_modules_signed ----------------------------------------

modules=${fake}/lib/modules/test/misc
mkdir -p "${modules}"
: > "${modules}/vboxdrv.ko"
: > "${modules}/vboxnetflt.ko"

cat > "${scratch}/bin/modinfo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'filename:       %s\n' "$1"
case "${STUB_SIGNED:-1}:${1}" in
  0:*) ;;
  *unsigned*) ;;
  *) printf 'signer:         DKMS module signing key\n' ;;
esac
EOF
chmod 0755 "${scratch}/bin/modinfo"

run_signed() { # $1 = stub signedness, $2 = module dir
  env PATH="${scratch}/bin:${PATH}" STUB_SIGNED="${1}" MOD_DIR="${2}" \
    bash -c '
      set -euo pipefail
      '"$(cat "${scratch}/signed.sh")"'
      vbox_modules_signed "${MOD_DIR}"
    '
}

run_signed 1 "${modules}" || fail 'a fully signed module set must report signed'
if run_signed 0 "${modules}"; then
  fail 'an unsigned module set must report unsigned so the build is retried'
fi

# One unsigned module among signed ones must still report unsigned.
: > "${modules}/vboxnetadp-unsigned.ko"
if run_signed 1 "${modules}"; then
  fail 'a single unsigned module must make the whole set report unsigned'
fi
rm -f "${modules}/vboxnetadp-unsigned.ko"

# A compressed module must be handled too — modinfo decompresses, the glob must
# not stop at a bare .ko suffix.
: > "${modules}/vboxnetflt-unsigned.ko.xz"
if run_signed 1 "${modules}"; then
  fail 'a compressed unsigned module must be caught by the .ko* glob'
fi
rm -f "${modules}/vboxnetflt-unsigned.ko.xz"

# No modules built at all must report unsigned, not vacuously signed.
rm -f "${modules}"/vbox*.ko
if run_signed 1 "${modules}"; then
  fail 'an empty module directory must report unsigned, not vacuously signed'
fi

# A directory that does not exist at all must report unsigned, never crash.
if run_signed 1 "${modules}/absent"; then
  fail 'a missing module directory must report unsigned'
fi

# An empty directory argument must report unsigned rather than glob the
# filesystem root looking for vbox modules.
if run_signed 1 ''; then
  fail 'an empty module directory argument must report unsigned'
fi

printf 'Fedora VirtualBox Secure Boot signing smoke passed.\n'
