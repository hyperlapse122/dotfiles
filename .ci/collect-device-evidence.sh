#!/usr/bin/env bash
# collect-device-evidence.sh — parameterized POSIX device evidence collector
# (Fedora and macOS legs; Windows uses collect-device-evidence.ps1).
#
# Measures a CANDIDATE checkout on a protected device and emits one
# attestation-ready record without applying it to live HOME or changing device
# state. Foundational identity/render checks run in isolated scratch state.
#
# Claims come only from the protected workflow via repeated --claim flags.
# G0/G1a claims execute concrete read-only repository/release/channel probes;
# their observed availability may be pass or fail. Human-only G1b visual
# claims require --proof-file outside the candidate checkout. That strict JSON
# must bind each claim, device, candidate commit, canonical snapshot identity
# and digest, observed pass/fail status, and non-empty detail. The proof checks
# are folded into this record before the workflow attests its bytes. Unknown,
# duplicate, missing, or unmeasured claims fail before record write.
#
# Required parameters:
#   --device-id ID            protected device allowlist id (e.g. fedora-arm64)
#   --os OS                   fedora | macos
#   --arch ARCH               x64 | arm64
#   --candidate-dir DIR       git checkout of the candidate under measurement
#   --candidate-commit SHA    40-hex commit the checkout MUST be at
#   --support-snapshot PATH   canonical support-matrix snapshot (inside candidate)
#   --repository OWNER/REPO   GitHub repository the attestation must bind to
#   --workflow-ref REF        default-branch workflow ref
#                             (OWNER/REPO/.github/workflows/device-smoke.yml@refs/heads/<branch>)
#   --workflow-sha SHA        git blob SHA of device-smoke.yml on the default branch
#   --environment NAME        protected GitHub environment gating the run
#   --runner-class CLASS      github-hosted | self-hosted
#   --runner-labels A,B,C     runner labels; MUST equal the policy allowlist entry
#   --output FILE             evidence record destination (JSON)
#   --claim ID                protected-policy claim id (repeatable)
#   --proof-file FILE         operator proof for requested G1b visual claims
set -euo pipefail

fail() { printf 'collect-device-evidence: %s\n' "$*" >&2; exit 1; }

device_id='' os='' arch='' candidate_dir='' candidate_commit=''
support_snapshot='' repository='' workflow_ref='' workflow_sha=''
environment='' runner_class='' output='' runner_labels='' proof_file=''
claims=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --device-id)          device_id=${2:?missing value for --device-id}; shift 2 ;;
    --os)                 os=${2:?missing value for --os}; shift 2 ;;
    --arch)               arch=${2:?missing value for --arch}; shift 2 ;;
    --candidate-dir)      candidate_dir=${2:?missing value for --candidate-dir}; shift 2 ;;
    --candidate-commit)   candidate_commit=${2:?missing value for --candidate-commit}; shift 2 ;;
    --support-snapshot)   support_snapshot=${2:?missing value for --support-snapshot}; shift 2 ;;
    --repository)         repository=${2:?missing value for --repository}; shift 2 ;;
    --workflow-ref)       workflow_ref=${2:?missing value for --workflow-ref}; shift 2 ;;
    --workflow-sha)       workflow_sha=${2:?missing value for --workflow-sha}; shift 2 ;;
    --environment)        environment=${2:?missing value for --environment}; shift 2 ;;
    --runner-class)       runner_class=${2:?missing value for --runner-class}; shift 2 ;;
    --runner-labels)      runner_labels=${2:?missing value for --runner-labels}; shift 2 ;;
    --output)             output=${2:?missing value for --output}; shift 2 ;;
    --claim)              claims+=("${2:?missing value for --claim}"); shift 2 ;;
    --proof-file)         proof_file=${2:?missing value for --proof-file}; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

for pair in \
  "device-id:${device_id}" "os:${os}" "arch:${arch}" \
  "candidate-dir:${candidate_dir}" "candidate-commit:${candidate_commit}" \
  "support-snapshot:${support_snapshot}" "repository:${repository}" \
  "workflow-ref:${workflow_ref}" "workflow-sha:${workflow_sha}" \
  "environment:${environment}" "runner-class:${runner_class}" \
  "runner-labels:${runner_labels}" "output:${output}"; do
  [ -n "${pair#*:}" ] || fail "missing required parameter --${pair%%:*}"
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v git >/dev/null 2>&1 || fail "git is required"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail "neither sha256sum nor shasum is available"
  fi
}

# sha256 over the validator's canonical JSON form (sorted keys, compact) —
# .ci/validate-device-evidence.mjs canonicalJson. For the ASCII-only support
# matrix `jq -S -c` is byte-identical (verified against snapshotDigest()).
canonical_json_digest() {
  local canonical
  canonical=$(jq -S -c . "$1" | tr -d '\n') \
    || fail "support snapshot is not valid JSON: $1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$canonical" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$canonical" | shasum -a 256 | awk '{print $1}'
  fi
}

# --- claim validation (fail closed on anything the registry cannot measure) --
automated_registry=" runtime-arch candidate-commit support-snapshot render-smoke chrome-native-arm64-available cider-native-arm64-available edge-native-arm64-available onepassword-native-arm64-available wezterm-stable-release-published wezterm-kitty-unicode-placeholders-in-stable wezterm-upstream-stable-rpm-for-current-fedora wezterm-stable-homebrew-cask "
visual_registry=" inline-image-renders-in-tmux inline-image-survives-scroll inline-image-survives-redraw inline-image-survives-resize inline-image-survives-split inline-image-over-ssh-to-fedora-vm "
if [ "${#claims[@]}" -eq 0 ]; then
  claims=(runtime-arch candidate-commit support-snapshot render-smoke)
fi
seen_claims=' '
has_visual=false
for claim in "${claims[@]}"; do
  case "$seen_claims" in *" $claim "*) fail "duplicate claim '$claim'" ;; esac
  seen_claims="${seen_claims}${claim} "
  case "${automated_registry}${visual_registry}" in
    *" $claim "*) ;;
    *) fail "unknown claim '$claim' — no trusted probe measures it" ;;
  esac
  case "$visual_registry" in *" $claim "*) has_visual=true ;; esac
done
claimed() {
  local probe=$1 c
  for c in "${claims[@]}"; do [ "$c" = "$probe" ] && return 0; done
  return 1
}

# --- input shape validation (fail closed) ----------------------------------
printf '%s' "$candidate_commit" | grep -qE '^[0-9a-f]{40}$' \
  || fail "--candidate-commit is not a 40-hex SHA: $candidate_commit"
printf '%s' "$workflow_sha" | grep -qE '^[0-9a-f]{40}$' \
  || fail "--workflow-sha is not a 40-hex SHA: $workflow_sha"
printf '%s' "$repository" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
  || fail "--repository is not OWNER/REPO: $repository"
case "$os" in fedora|macos) ;; *) fail "--os must be fedora or macos, got: $os" ;; esac
case "$arch" in x64|arm64) ;; *) fail "--arch must be x64 or arm64, got: $arch" ;; esac
case "$runner_class" in github-hosted|self-hosted) ;; *)
  fail "--runner-class must be github-hosted or self-hosted, got: $runner_class" ;;
esac
case "$workflow_ref" in
  "$repository"/.github/workflows/device-smoke.yml@refs/heads/*) ;;
  *) fail "--workflow-ref must pin device-smoke.yml on a branch of $repository, got: $workflow_ref" ;;
esac
[ -f "$support_snapshot" ] || fail "support snapshot not found: $support_snapshot"
[ -d "$candidate_dir" ] || fail "candidate checkout not found: $candidate_dir"

# --- probe: runtime-arch ------------------------------------------------------
kernel=$(uname -s)
machine=$(uname -m)
case "$machine" in
  x86_64|amd64)   runtime_arch=x64 ;;
  aarch64|arm64)  runtime_arch=arm64 ;;
  *) fail "unsupported runtime architecture: $machine" ;;
esac
[ "$runtime_arch" = "$arch" ] \
  || fail "runtime architecture $runtime_arch ($machine) does not match declared --arch $arch"
case "$os" in
  fedora)
    [ "$kernel" = Linux ] || fail "--os fedora but kernel is $kernel"
    [ -r /etc/os-release ] || fail "--os fedora but /etc/os-release is unreadable"
    . /etc/os-release
    [ "${ID:-}" = fedora ] || fail "--os fedora but os-release ID is ${ID:-unknown}"
    ;;
  macos)
    [ "$kernel" = Darwin ] || fail "--os macos but kernel is $kernel"
    ;;
esac

# --- probe: candidate-commit ----------------------------------------------------
actual_commit=$(git -C "$candidate_dir" rev-parse HEAD 2>/dev/null) \
  || fail "candidate dir is not a git work tree: $candidate_dir"
[ "$actual_commit" = "$candidate_commit" ] \
  || fail "candidate checkout is at $actual_commit, expected $candidate_commit"

# --- probe: support-snapshot ------------------------------------------------------
# Candidate-controlled files are measured subjects only: the collector hashes
# ITSELF ($0 — the default-branch-pinned copy the protected workflow fetches)
# and the canonical support snapshot; the candidate never supplies the
# collector or the policy that judges it.
collector_sha=$(sha256_file "$0")
snapshot_sha=$(canonical_json_digest "$support_snapshot")

# --- protected-policy claim probes -------------------------------------------
checks_json='[]'
append_check() {
  local name=$1 status=$2 detail=$3
  checks_json=$(jq --arg name "$name" --arg status "$status" --arg detail "$detail" \
    '. + [{name: $name, status: $status, detail: $detail}]' <<<"$checks_json")
}

probe_scratch=$(mktemp -d "${TMPDIR:-/tmp}/device-claims.XXXXXX")
render_scratch=''
cleanup() {
  rm -rf -- "$probe_scratch"
  [ -z "$render_scratch" ] || rm -rf -- "$render_scratch"
}
trap cleanup EXIT
wezterm_release=''
load_wezterm_release() {
  [ -n "$wezterm_release" ] && return 0
  command -v curl >/dev/null 2>&1 || return 1
  wezterm_release=$(curl -fsSL --max-time 30 \
    https://api.github.com/repos/wezterm/wezterm/releases/latest 2>/dev/null) || return 1
  jq -e '.draft == false and .prerelease == false and (.tag_name | type == "string" and length > 0)' \
    <<<"$wezterm_release" >/dev/null
}

probe_claim() {
  local claim=$1 result detail package asset_re
  result=fail
  case "$claim" in
    runtime-arch)
      result=pass; detail="uname -m = $machine"
      ;;
    candidate-commit)
      result=pass; detail="checkout HEAD = $candidate_commit"
      ;;
    support-snapshot)
      result=pass; detail="sha256 = $snapshot_sha"
      ;;
    render-smoke)
      result=pass; detail="isolated execute-template of $probe_template rendered valid bash; live HOME untouched"
      ;;
    chrome-native-arm64-available|edge-native-arm64-available|onepassword-native-arm64-available)
      [ "$os" = fedora ] && [ "$arch" = arm64 ] ||
        fail "claim '$claim' is not applicable to $os/$arch"
      case "$claim" in
        chrome-*) package=google-chrome-stable ;;
        edge-*) package=microsoft-edge-stable ;;
        onepassword-*) package=1password ;;
      esac
      if command -v dnf >/dev/null 2>&1 && dnf -q \
          --setopt="cachedir=$probe_scratch/dnf-cache" \
          --setopt="persistdir=$probe_scratch/dnf-state" \
          repoquery --refresh --arch aarch64 "$package" >"$probe_scratch/repoquery" 2>/dev/null &&
          [ -s "$probe_scratch/repoquery" ]; then
        result=pass; detail="dnf repository metadata publishes $package for aarch64"
      else
        detail="dnf repository metadata did not publish $package for aarch64"
      fi
      ;;
    cider-native-arm64-available)
      [ "$os" = fedora ] && [ "$arch" = arm64 ] ||
        fail "claim '$claim' is not applicable to $os/$arch"
      if command -v curl >/dev/null 2>&1 &&
          curl -fsSL --max-time 30 https://api.github.com/repos/ciderapp/Cider/releases/latest \
            >"$probe_scratch/cider-release.json" 2>/dev/null &&
          jq -e '[.assets[].name | select(test("(aarch64|arm64).*\\.rpm$|\\.rpm.*(aarch64|arm64)"; "i"))] | length > 0' \
            "$probe_scratch/cider-release.json" >/dev/null; then
        result=pass; detail="latest Cider release publishes an arm64 RPM asset"
      else
        detail="latest Cider release publishes no arm64 RPM asset"
      fi
      ;;
    wezterm-stable-release-published)
      if load_wezterm_release; then
        result=pass; detail="GitHub latest release is stable tag $(jq -r '.tag_name' <<<"$wezterm_release")"
      else
        detail="GitHub latest release probe found no stable WezTerm release"
      fi
      ;;
    wezterm-kitty-unicode-placeholders-in-stable)
      if load_wezterm_release &&
          jq -e '(.body // "") | test("kitty.{0,120}unicode.{0,40}placeholder|unicode.{0,40}placeholder.{0,120}kitty"; "i")' \
            <<<"$wezterm_release" >/dev/null; then
        result=pass; detail="stable WezTerm release notes explicitly document Kitty Unicode placeholders"
      else
        detail="stable WezTerm release notes do not document Kitty Unicode placeholders"
      fi
      ;;
    wezterm-upstream-stable-rpm-for-current-fedora)
      [ "$os" = fedora ] || fail "claim '$claim' is not applicable to $os"
      asset_re="(fedora|fc)${VERSION_ID}.*(${machine}|${arch}).*\\.rpm$|(${machine}|${arch}).*(fedora|fc)${VERSION_ID}.*\\.rpm$"
      if load_wezterm_release &&
          jq -e --arg re "$asset_re" '[.assets[].name | select(test($re; "i"))] | length > 0' \
            <<<"$wezterm_release" >/dev/null; then
        result=pass; detail="stable WezTerm release publishes a Fedora ${VERSION_ID} ${machine} RPM"
      else
        detail="stable WezTerm release publishes no Fedora ${VERSION_ID} ${machine} RPM"
      fi
      ;;
    wezterm-stable-homebrew-cask)
      [ "$os" = macos ] || fail "claim '$claim' is not applicable to $os"
      if command -v brew >/dev/null 2>&1 &&
          HOMEBREW_NO_AUTO_UPDATE=1 brew info --cask --json=v2 wezterm \
            >"$probe_scratch/brew-wezterm.json" 2>/dev/null &&
          jq -e '.casks | length == 1 and .[0].token == "wezterm" and
                 (.[0].version | type == "string" and length > 0 and . != "latest")' \
            "$probe_scratch/brew-wezterm.json" >/dev/null; then
        result=pass; detail="Homebrew stable cask metadata publishes WezTerm version $(jq -r '.casks[0].version' "$probe_scratch/brew-wezterm.json")"
      else
        detail="Homebrew stable cask metadata did not publish a versioned WezTerm cask"
      fi
      ;;
    *) fail "claim '$claim' has no automated probe" ;;
  esac
  append_check "$claim" "$result" "$detail"
}

# --- probe: render-smoke (never touches live HOME) --------------------------------
case "$os" in
  fedora) probe_template=.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl ;;
  macos)  probe_template=.chezmoiscripts/20-darwin/run_onchange_before_homebrew.sh.tmpl ;;
esac
if claimed render-smoke; then
  command -v chezmoi >/dev/null 2>&1 \
    || fail "chezmoi is required on PATH (render-smoke was claimed)"
  [ -f "$candidate_dir/$probe_template" ] \
    || fail "candidate is missing the render probe template: $probe_template"
  render_scratch=$(mktemp -d "${TMPDIR:-/tmp}/device-evidence.XXXXXX")
  scratch=$render_scratch
  mkdir -p "$scratch/bin" "$scratch/target"
  : > "$scratch/empty.toml"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "${1-}" in'
    printf '%s\n' '  whoami) printf "dummy@example.invalid\n" ;;'
    printf '%s\n' '  *) printf "dummy-secret" ;;'
    printf '%s\n' 'esac'
  } > "$scratch/bin/op"
  chmod 700 "$scratch/bin/op"
  # Candidate templates execute as code during rendering. Give the child only
  # the non-secret environment required for the isolated render so ambient
  # GitHub OIDC/action tokens and other credential variables are unavailable.
  if ! env -i HOME="$scratch/home" PATH="$scratch/bin:$PATH" TMPDIR="$scratch" chezmoi \
        --config "$scratch/empty.toml" \
        --source "$candidate_dir" \
        --destination "$scratch/target" \
        execute-template < "$candidate_dir/$probe_template" > "$scratch/rendered.sh" 2> "$scratch/render.err"; then
    fail "render smoke measurement failed — chezmoi execute-template: $(head -n 1 "$scratch/render.err")"
  fi
  if ! bash -n "$scratch/rendered.sh" 2> "$scratch/bashn.err"; then
    fail "render smoke measurement failed — rendered probe is not valid bash: $(head -n 1 "$scratch/bashn.err")"
  fi
fi

# --- bind requested claims to measured or human-attested proof ----------------
expected_visual='[]'
for claim in "${claims[@]}"; do
  case "$visual_registry" in
    *" $claim "*) expected_visual=$(jq --arg claim "$claim" '. + [$claim]' <<<"$expected_visual") ;;
  esac
done
if $has_visual; then
  [ -n "$proof_file" ] && [ -f "$proof_file" ] ||
    fail "requested visual claims require --proof-file"
  proof_dir=$(cd -- "$(dirname -- "$proof_file")" && pwd -P) ||
    fail "cannot resolve proof file directory"
  proof_abs="$proof_dir/$(basename -- "$proof_file")"
  candidate_abs=$(cd -- "$candidate_dir" && pwd -P)
  case "$proof_abs" in
    "$candidate_abs"|"$candidate_abs"/*) fail "proof file must be outside the candidate checkout" ;;
  esac
  jq -e \
    --arg device "$device_id" \
    --arg commit "$candidate_commit" \
    --arg snapshot "$snapshot_sha" \
    --argjson claims "$expected_visual" '
    type == "object" and
    keys == ["candidate", "checks", "device", "schemaVersion", "supportSnapshot"] and
    .schemaVersion == 1 and
    (.device | type == "object" and keys == ["id"]) and .device.id == $device and
    (.candidate | type == "object" and keys == ["commit"]) and .candidate.commit == $commit and
    (.supportSnapshot | type == "object" and keys == ["path", "sha256"]) and
    .supportSnapshot.path == ".ci/support-matrix.json" and .supportSnapshot.sha256 == $snapshot and
    (.checks | type == "array" and length == ($claims | length)) and
    ([.checks[].name] | sort) == ($claims | sort) and
    ([.checks[].name] | unique | length) == (.checks | length) and
    all(.checks[];
      type == "object" and keys == ["detail", "name", "status"] and
      (.status == "pass" or .status == "fail") and
      (.detail | type == "string" and length > 0 and length <= 500))
  ' "$proof_abs" >/dev/null || fail "proof file is malformed or not exactly bound to claims/device/commit/snapshot"
  if jq -r '.checks[].detail' "$proof_abs" |
      grep -qiE 'BEGIN .*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_|Bearer [A-Za-z0-9._~+/=-]{10,}|password[[:space:]]*[:=]|secret[[:space:]]*[:=]'; then
    fail "proof detail contains secret-shaped data"
  fi
elif [ -n "$proof_file" ]; then
  fail "--proof-file was supplied but no visual claim was requested"
fi

for claim in "${claims[@]}"; do
  case "$visual_registry" in
    *" $claim "*)
      proof_check=$(jq -c --arg claim "$claim" '.checks[] | select(.name == $claim)' "$proof_abs")
      checks_json=$(jq --argjson check "$proof_check" '. + [$check]' <<<"$checks_json")
      ;;
    *) probe_claim "$claim" ;;
  esac
done

# --- emit the evidence record -------------------------------------------------

labels_json=$(printf '%s' "$runner_labels" | jq -R 'split(",")')
collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$(dirname "$output")"
jq -n \
  --arg deviceId "$device_id" \
  --arg os "$os" \
  --arg arch "$arch" \
  --arg runnerClass "$runner_class" \
  --argjson runnerLabels "$labels_json" \
  --arg collectorPath ".ci/collect-device-evidence.sh" \
  --arg collectorSha "$collector_sha" \
  --arg candidateCommit "$candidate_commit" \
  --arg snapshotPath ".ci/support-matrix.json" \
  --arg snapshotSha "$snapshot_sha" \
  --arg issuer "https://token.actions.githubusercontent.com" \
  --arg repository "$repository" \
  --arg workflowRef "$workflow_ref" \
  --arg workflowSha "$workflow_sha" \
  --arg environment "$environment" \
  --arg runtimeArch "$machine" \
  --argjson checks "$checks_json" \
  --arg collectedAt "$collected_at" \
  '{
    schemaVersion: 1,
    device: {
      id: $deviceId,
      os: $os,
      arch: $arch,
      runnerClass: $runnerClass,
      runnerLabels: $runnerLabels
    },
    collector: { path: $collectorPath, sha256: $collectorSha },
    candidate: { commit: $candidateCommit },
    supportSnapshot: { path: $snapshotPath, sha256: $snapshotSha },
    attestation: {
      kind: "github-artifact-attestation",
      bundlePath: "attestation.sigstore.json",
      issuer: $issuer,
      repository: $repository,
      workflowRef: $workflowRef,
      workflowSha: $workflowSha,
      environment: $environment
    },
    measurements: {
      runtimeArch: $runtimeArch,
      checks: $checks
    },
    collectedAt: $collectedAt
  }' > "$output"

printf 'collect-device-evidence: wrote %s (device=%s arch=%s candidate=%s snapshot=%s claims=%s)\n' \
  "$output" "$device_id" "$runtime_arch" "$candidate_commit" "$snapshot_sha" "${claims[*]}"
