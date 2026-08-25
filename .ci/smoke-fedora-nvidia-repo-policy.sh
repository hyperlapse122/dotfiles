#!/usr/bin/env bash

set -euxo pipefail

rendered_installer=${1:?usage: smoke-fedora-nvidia-repo-policy.sh <rendered-fedora-installer>}
if [[ ! -f "${rendered_installer}" ]]; then
  printf 'missing rendered Fedora installer: %s\n' "${rendered_installer}" >&2
  exit 1
fi

scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-${HOME}/.cache}}
mkdir -p "${scratch_root}"
scratch=$(mktemp -d "${scratch_root}/fedora-nvidia-policy.XXXXXX")
cleanup() {
  rm -f \
    "${scratch}/bin/dnf" \
    "${scratch}/array.sh" \
    "${scratch}/function.sh" \
    "${scratch}/harness.sh" \
    "${scratch}/present.log" \
    "${scratch}/absent.log" \
    "${scratch}/non-nvidia.log" \
    "${scratch}/repeat.log"
  rmdir "${scratch}/bin" "${scratch}"
}
trap cleanup EXIT
mkdir -p "${scratch}/bin"

array_start=$(grep -n '^nvidia_rpmfusion_excludes=($' "${rendered_installer}" | cut -d: -f1 || true)
function_start=$(grep -n '^configure_nvidia_repo_policy() {$' "${rendered_installer}" | cut -d: -f1 || true)
existing_host_call=$(grep -n '^[[:space:]]*configure_nvidia_repo_policy$' "${rendered_installer}" | cut -d: -f1 | head -1 || true)
cuda_repo_setup=$(grep -n '^setup_nvidia_repos() {$' "${rendered_installer}" | cut -d: -f1 || true)

if [[ -z "${array_start}" || -z "${function_start}" || -z "${existing_host_call}" || -z "${cuda_repo_setup}" ]]; then
  printf 'rendered Fedora installer is missing the NVIDIA repository policy contract\n' >&2
  exit 1
fi
if (( existing_host_call <= cuda_repo_setup )); then
  printf 'NVIDIA repository policy must run inside setup_nvidia_repos\n' >&2
  exit 1
fi

if [[ ! -s "${rendered_installer}" ]]; then
  printf 'rendered Fedora installer is empty\n' >&2
  exit 1
fi

for package in cuda-drivers cuda-toolkit-13-3 kmod-nvidia-latest-dkms nvidia-driver; do
  grep -Eq "^[[:space:]]+[\"']?${package}[\"']?\r?$" "${rendered_installer}" || { printf "missing package %s in rendered installer\n" "${package}" >&2; exit 1; }
done

sed -n "${array_start},/^[[:space:]]*)$/p" "${rendered_installer}" > "${scratch}/array.sh"
sed -n "${function_start},/^[[:space:]]*}$/p" "${rendered_installer}" > "${scratch}/function.sh"

cat > "${scratch}/bin/dnf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${DNF_LOG:?}"
if [[ " $* " == *' repo list '* && "${DNF_HAS_RPMFUSION:-0}" == 1 ]]; then
  printf '%s\n' \
    'repo id                                           repo name                              status' \
    'rpmfusion-nonfree-nvidia-driver                   RPM Fusion NVIDIA Driver               enabled'
fi
EOF
chmod 0755 "${scratch}/bin/dnf"

cat > "${scratch}/harness.sh" <<EOF
#!/usr/bin/env bash
DNF=(dnf)
$(cat "${scratch}/array.sh")
$(cat "${scratch}/function.sh")
configure_nvidia_repo_policy
EOF
chmod 0755 "${scratch}/harness.sh"

expected='config-manager setopt rpmfusion-nonfree*.excludepkgs=akmod-nvidia*,kmod-nvidia*,nvidia-modprobe,nvidia-persistenced,nvidia-settings,nvidia-xconfig,xorg-x11-drv-nvidia*'

present_log="${scratch}/present.log"
env PATH="${scratch}/bin:${PATH}" DNF_HAS_RPMFUSION=1 DNF_LOG="${present_log}" \
  "${scratch}/harness.sh"
grep -Fxq -- "${expected}" "${present_log}" || { printf "expected override not found in log. log contains:\n"; cat "${present_log}"; exit 1; }

absent_log="${scratch}/absent.log"
: > "${absent_log}"
env PATH="${scratch}/bin:${PATH}" DNF_HAS_RPMFUSION=0 DNF_LOG="${absent_log}" \
  "${scratch}/harness.sh"
if grep -Fq 'config-manager setopt' "${absent_log}"; then
  printf 'absent RPM Fusion repositories must not receive an override\n' >&2
  exit 1
fi

repeat_log="${scratch}/repeat.log"
: > "${repeat_log}"
for _ in 1 2; do
  env PATH="${scratch}/bin:${PATH}" DNF_HAS_RPMFUSION=1 DNF_LOG="${repeat_log}" \
    "${scratch}/harness.sh"
done
if [[ $(grep -Fxc -- "${expected}" "${repeat_log}") -ne 2 ]]; then
  printf 'repeated reconciliation must emit the same repository override\n' >&2
  exit 1
fi

printf 'Fedora NVIDIA repository policy smoke passed.\n'
