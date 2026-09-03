#!/usr/bin/env bash

# Assert the Fedora NVIDIA repository-and-package policy for EVERY driver branch.
#
# One rendered installer covers both branches: selection happens at run time on
# FACT_GPU_ARCH, which is what lets this harness drive both shapes from a single
# render and needs no live host.
#
# WHAT THE PREVIOUS VERSION MISSED. It greased four fixed current-branch package
# literals and asserted one hardcoded RPM Fusion exclusion string. It never
# extracted resolve_nvidia_branch, never drove a legacy host, and never checked
# that the legacy branch empties the RPM Fusion exclusions or skips the CUDA
# repofile -- so the whole second branch, added with its own package set and its
# own package source, was unasserted. It also anchored the exclusion array by an
# unindented `nvidia_rpmfusion_excludes=(`, so the `=()` reset a legacy host takes
# inside resolve_nvidia_branch was invisible to it.
#
# THE POLICY UNDER TEST, both directions. A current-branch host excludes the
# driver names from RPM Fusion so the vendor CUDA repository wins. A legacy-branch
# host does the reverse: it clears those exclusions AND excludes the same names
# from the CUDA repository, because a host that applied before the branch axis
# existed still carries cuda-fedora*.repo and both sources would otherwise serve
# the same driver packages.

set -euxo pipefail

rendered_installer=${1:?usage: smoke-fedora-nvidia-repo-policy.sh <rendered-fedora-installer>}
if [[ ! -f "${rendered_installer}" ]]; then
  printf 'missing rendered Fedora installer: %s\n' "${rendered_installer}" >&2
  exit 1
fi
if [[ ! -s "${rendered_installer}" ]]; then
  printf 'rendered Fedora installer is empty\n' >&2
  exit 1
fi

scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-${HOME}/.cache}}
mkdir -p "${scratch_root}"
scratch=$(mktemp -d "${scratch_root}/fedora-nvidia-policy.XXXXXX")
trap 'rm -rf "${scratch}"' EXIT
mkdir -p "${scratch}/bin" "${scratch}/home"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# --- Structural contract ----------------------------------------------------
#
# The branch policy is generated from .chezmoidata/nvidia.yaml, so the installer
# must carry the selector and both exclusion halves, and the policy must run
# inside repository setup rather than beside it.
for fn in resolve_nvidia_branch conflicting_nvidia_branch \
  configure_rpmfusion_exclusions configure_cuda_exclusions \
  configure_nvidia_repo_policy setup_nvidia_repos; do
  grep -qx "${fn}() {" "${rendered_installer}" ||
    fail "rendered Fedora installer is missing ${fn}"
done

policy_call=$(grep -n '^[[:space:]]*configure_nvidia_repo_policy$' "${rendered_installer}" | cut -d: -f1 | head -1)
repo_setup=$(grep -n '^setup_nvidia_repos() {$' "${rendered_installer}" | cut -d: -f1)
[[ -n "${policy_call}" && -n "${repo_setup}" ]] ||
  fail 'rendered Fedora installer is missing the NVIDIA repository policy contract'
if ((policy_call <= repo_setup)); then
  fail 'NVIDIA repository policy must run inside setup_nvidia_repos'
fi

# --- Extraction -------------------------------------------------------------
#
# One contiguous region rather than per-symbol greps: the generated arrays, the
# branch selector and both exclusion halves sit together at top level, and a
# region keeps the `nvidia_rpmfusion_excludes=()` reset INSIDE
# resolve_nvidia_branch, which a per-array anchor cannot see.
region_start=$(grep -n '^nvidia_packages=($' "${rendered_installer}" | cut -d: -f1)
region_end=$(awk '/^conflicting_nvidia_branch\(\) \{$/ { inside = 1 } inside && /^\}$/ { print NR; exit }' \
  "${rendered_installer}")
[[ -n "${region_start}" && -n "${region_end}" ]] ||
  fail 'rendered Fedora installer does not carry the branch policy region'
sed -n "${region_start},${region_end}p" "${rendered_installer}" > "${scratch}/policy.sh"

grep -qx 'nvidia_cuda_excludes=(' "${scratch}/policy.sh" ||
  fail 'the branch policy region carries no generated CUDA exclusion array'
# The reset the legacy branch takes. Extracting a region rather than one anchored
# array is what makes this assertion possible at all.
grep -q 'nvidia_rpmfusion_excludes=()' "${scratch}/policy.sh" ||
  fail 'the branch policy region does not clear the RPM Fusion exclusions for a branch with its own source'

# --- The dnf stub -----------------------------------------------------------
cat > "${scratch}/bin/dnf" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${DNF_LOG:?}"
if [[ " $* " == *' repo list '* && "${DNF_HAS_RPMFUSION:-0}" == 1 ]]; then
  printf '%s\n' \
    'repo id                                           repo name                              status' \
    'rpmfusion-nonfree-nvidia-driver                   RPM Fusion NVIDIA Driver               enabled'
fi
exit 0
EOF
chmod 0755 "${scratch}/bin/dnf"

# `rpm -q` decides which branch marker counts as installed, which is what
# conflicting_nvidia_branch reads. $RPM_INSTALLED is a space-delimited set.
cat > "${scratch}/bin/rpm" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1-}" == -q ]] || exit 1
for pkg in ${RPM_INSTALLED:-}; do
  [[ "$pkg" == "${2-}" ]] && exit 0
done
exit 1
EOF
chmod 0755 "${scratch}/bin/rpm"

# $1 = FACT_GPU_ARCH, $2 = shell driving the extracted region. HOME is redirected
# because the RPM Fusion half carries a declared skip that clears its own state
# entry, and a smoke test must not touch the caller's real skip records.
run_policy() {
  local arch=$1 body=$2
  : > "${scratch}/dnf.log"
  env HOME="${scratch}/home" XDG_STATE_HOME="${scratch}/home/state" \
    PATH="${scratch}/bin:${PATH}" DNF_LOG="${scratch}/dnf.log" \
    DNF_HAS_RPMFUSION="${DNF_HAS_RPMFUSION:-1}" RPM_INSTALLED="${RPM_INSTALLED:-}" \
    FACT_GPU_ARCH="${arch}" \
    bash -c '
      set -uo pipefail
      DNF=(dnf)
      SUDO=()
      '"$(cat "${scratch}/policy.sh")"'
      '"${body}"'
    '
}

logged() { grep -Fxq -- "$1" "${scratch}/dnf.log"; }

# --- Current branch ---------------------------------------------------------
#
# `latest` is the branch an architecture listed as current resolves to. The
# package set, the RPM Fusion exclusions and the CLEARED CUDA exclusions are all
# asserted from the resolved state rather than from fixed literals, so a data edit
# that changes the set changes this assertion with it.
current_out=$(run_policy '' '
  nvidia_branch=latest
  nvidia_branch_source=cuda
  configure_nvidia_repo_policy
  printf "packages=%s\n" "${nvidia_packages[*]}"
  printf "rpmfusion=%s\n" "${nvidia_rpmfusion_excludes[*]}"
')
grep -q 'excludepkgs=akmod-nvidia\*,kmod-nvidia\*' "${scratch}/dnf.log" ||
  { printf 'current branch did not receive the RPM Fusion exclusions. log:\n'; cat "${scratch}/dnf.log"; exit 1; }
logged 'config-manager setopt cuda-fedora*.excludepkgs=' ||
  { printf 'a cuda-branch host must CLEAR the CUDA exclusions, not leave them set. log:\n'; cat "${scratch}/dnf.log"; exit 1; }
grep -q 'packages=.*kmod-nvidia-latest-dkms' <<<"${current_out}" ||
  fail 'the current branch does not select the DKMS package set'

# --- Legacy branch ----------------------------------------------------------
#
# Driven through resolve_nvidia_branch itself, on the architecture the table
# classifies as legacy, so the selector is what produces the state under test.
legacy_out=$(run_policy pascal '
  resolve_nvidia_branch || { printf "resolve-failed\n"; exit 1; }
  printf "branch=%s\n" "$nvidia_branch"
  printf "source=%s\n" "$nvidia_branch_source"
  printf "build=%s\n" "$nvidia_build_system"
  printf "packages=%s\n" "${nvidia_packages[*]}"
  printf "rpmfusion=[%s]\n" "${nvidia_rpmfusion_excludes[*]-}"
  configure_nvidia_repo_policy
')
grep -q 'source=rpmfusion' <<<"${legacy_out}" ||
  fail 'the legacy architecture does not resolve to the RPM Fusion package source'
grep -q 'build=akmod' <<<"${legacy_out}" ||
  fail 'the legacy architecture does not resolve to the akmod build system'
grep -q 'packages=.*akmod-nvidia-580xx' <<<"${legacy_out}" ||
  fail 'the legacy branch does not select the akmod package set'
if grep -q 'packages=.*kmod-nvidia-latest-dkms' <<<"${legacy_out}"; then
  fail 'the legacy branch must not keep the current-branch package set'
fi
grep -qx 'rpmfusion=\[\]' <<<"${legacy_out}" ||
  { printf 'the legacy branch must EMPTY the RPM Fusion exclusions. got:\n%s\n' "${legacy_out}"; exit 1; }
logged 'config-manager setopt rpmfusion-nonfree*.excludepkgs=' ||
  { printf 'the legacy branch did not clear the RPM Fusion exclusion value. log:\n'; cat "${scratch}/dnf.log"; exit 1; }
grep -q 'cuda-fedora\*.excludepkgs=cuda-drivers,' "${scratch}/dnf.log" ||
  { printf 'the legacy branch did not exclude the current-branch drivers from the CUDA repository. log:\n'; cat "${scratch}/dnf.log"; exit 1; }

# The CUDA repofile is added only for a branch the vendor repository serves.
# Asserted as rendered text, because setup_nvidia_repos also reaches the network.
repo_body=$(awk '/^setup_nvidia_repos\(\) \{$/ { inside = 1 } inside { print } inside && /^\}$/ { exit }' \
  "${rendered_installer}")
grep -Fq "if [[ \"\$nvidia_branch_source\" == 'cuda' ]]; then" <<<"${repo_body}" ||
  fail 'the CUDA repofile add is not gated on the resolved branch source'
grep -Fq 'developer.download.nvidia.com/compute/cuda/repos' <<<"${repo_body}" ||
  fail 'setup_nvidia_repos no longer adds the vendor CUDA repofile at all'

# The exclusion half must NOT be gated on the RPM Fusion probe: a legacy host with
# no RPM Fusion repository still carries the CUDA repofile that needs excluding.
policy_body=$(awk '/^configure_nvidia_repo_policy\(\) \{$/ { inside = 1 } inside { print } inside && /^\}$/ { exit }' \
  "${rendered_installer}")
grep -qx '  configure_cuda_exclusions' <<<"${policy_body}" ||
  fail 'configure_nvidia_repo_policy does not call the CUDA exclusion half'
cuda_body=$(awk '/^configure_cuda_exclusions\(\) \{$/ { inside = 1 } inside { print } inside && /^\}$/ { exit }' \
  "${rendered_installer}")
if grep -q 'rpmfusion' <<<"${cuda_body}"; then
  fail 'the CUDA exclusion half must not depend on RPM Fusion being present'
fi

# A legacy host with no RPM Fusion repository still gets its CUDA exclusion: the
# RPM Fusion half declares its skip and returns, and the CUDA half still runs.
DNF_HAS_RPMFUSION=0 run_policy pascal '
  resolve_nvidia_branch
  configure_nvidia_repo_policy
' >/dev/null
grep -q 'cuda-fedora\*.excludepkgs=cuda-drivers,' "${scratch}/dnf.log" ||
  { printf 'a legacy host without RPM Fusion lost its CUDA exclusion. log:\n'; cat "${scratch}/dnf.log"; exit 1; }
if grep -q 'rpmfusion-nonfree\*.excludepkgs' "${scratch}/dnf.log"; then
  printf 'absent RPM Fusion repositories must not receive an override. log:\n'
  cat "${scratch}/dnf.log"
  exit 1
fi

# --- Branch conflict --------------------------------------------------------
#
# The stop path nothing asserted before: a marker for a branch this host does not
# resolve to means both branches' modules would be installed, and the installer
# reports rather than removing anything.
conflict_out=$(RPM_INSTALLED='kmod-nvidia-latest-dkms' run_policy pascal '
  resolve_nvidia_branch
  printf "conflicting=%s\n" "${nvidia_conflicting_packages[*]}"
  if found=$(conflicting_nvidia_branch); then printf "conflict=%s\n" "$found"; else printf "conflict=none\n"; fi
')
grep -qx 'conflict=kmod-nvidia-latest-dkms' <<<"${conflict_out}" ||
  { printf 'a foreign branch marker was not reported as a conflict. got:\n%s\n' "${conflict_out}"; exit 1; }
if grep -q 'conflicting=.*akmod-nvidia-580xx' <<<"${conflict_out}"; then
  fail 'the resolved branch marker must not be listed as its own conflict'
fi

clean_out=$(RPM_INSTALLED='akmod-nvidia-580xx' run_policy pascal '
  resolve_nvidia_branch
  if found=$(conflicting_nvidia_branch); then printf "conflict=%s\n" "$found"; else printf "conflict=none\n"; fi
')
grep -qx 'conflict=none' <<<"${clean_out}" ||
  { printf 'the resolved branch marker was reported as a conflict. got:\n%s\n' "${clean_out}"; exit 1; }

# --- Unlisted architecture --------------------------------------------------
#
# An architecture the table does not classify must resolve to nothing, which is
# the fail-closed direction the whole branch axis exists to produce.
unlisted_out=$(run_policy 'turing-not-in-table' '
  if resolve_nvidia_branch; then printf "resolved=%s\n" "$nvidia_branch"; else printf "resolved=none\n"; fi
')
grep -qx 'resolved=none' <<<"${unlisted_out}" ||
  { printf 'an unlisted GPU architecture resolved to a branch. got:\n%s\n' "${unlisted_out}"; exit 1; }

# --- Idempotence ------------------------------------------------------------
#
# Repeated reconciliation writes the same value: the policy is a setopt, not an
# append, and a second apply on unchanged source must not drift. run_policy
# truncates the log each call, so each run is asserted to emit the value exactly
# once rather than counting two lines in one log.
for run in first second; do
  run_policy pascal '
    resolve_nvidia_branch
    configure_nvidia_repo_policy
  ' >/dev/null
  if [[ $(grep -c 'cuda-fedora\*.excludepkgs=cuda-drivers,' "${scratch}/dnf.log") -ne 1 ]]; then
    printf 'the %s reconciliation did not emit the CUDA exclusion exactly once. log:\n' "${run}"
    cat "${scratch}/dnf.log"
    exit 1
  fi
done

printf 'Fedora NVIDIA repository policy smoke passed (both driver branches).\n'
