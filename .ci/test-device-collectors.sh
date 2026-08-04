#!/usr/bin/env bash
# test-device-collectors.sh — focused fixtures for the POSIX device evidence
# collector (.ci/collect-device-evidence.sh). Runs natively on the OS/arch leg
# named by DEVICE_TEST_OS (fedora|macos) and DEVICE_TEST_ARCH (x64|arm64).
# Proves the collector emits a well-formed record on the happy path and fails
# closed — writing no record — on every trust violation.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
collector="${repo_root}/.ci/collect-device-evidence.sh"
[ -f "${collector}" ] || { echo "collector missing: ${collector}" >&2; exit 1; }

test_os=${DEVICE_TEST_OS:?'set DEVICE_TEST_OS (fedora|macos)'}
test_arch=${DEVICE_TEST_ARCH:?'set DEVICE_TEST_ARCH (x64|arm64)'}
case "${test_os}" in fedora|macos) ;; *) echo "bad DEVICE_TEST_OS: ${test_os}" >&2; exit 1 ;; esac
case "${test_arch}" in x64|arm64) ;; *) echo "bad DEVICE_TEST_ARCH: ${test_arch}" >&2; exit 1 ;; esac

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v chezmoi >/dev/null 2>&1 || { echo "chezmoi is required (render-smoke probe)" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node is required (schema validator)" >&2; exit 1; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/device-collector-test.XXXXXX")
trap 'rm -rf -- "${scratch}"' EXIT

candidate_commit=$(git -C "${repo_root}" rev-parse HEAD)
candidate_dir=${repo_root}
workflow_sha=$(git -C "${repo_root}" hash-object .github/workflows/device-smoke.yml)
repository="example/dotfiles"
workflow_ref="${repository}/.github/workflows/device-smoke.yml@refs/heads/main"
printf '{"schemaVersion":1,"targets":[]}\n' > "${scratch}/support-matrix.json"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
canonical_digest() {
  local canonical
  canonical=$(jq -S -c . "$1" | tr -d '\n')
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "${canonical}" | sha256sum | awk '{print $1}';
  else printf '%s' "${canonical}" | shasum -a 256 | awk '{print $1}'; fi
}

fail() { echo "test-device-collectors: $*" >&2; exit 1; }

run_collector() { # extra args appended; output fixed per-call via $1
  local out=$1; shift
  bash "${collector}" \
    --device-id "${test_os}-${test_arch}" \
    --os "${test_os}" \
    --arch "${test_arch}" \
    --candidate-dir "${candidate_dir}" \
    --candidate-commit "${candidate_commit}" \
    --support-snapshot "${scratch}/support-matrix.json" \
    --repository "${repository}" \
    --workflow-ref "${workflow_ref}" \
    --workflow-sha "${workflow_sha}" \
    --environment device-evidence \
    --runner-class github-hosted \
    --runner-labels "github-hosted,${test_os},${test_arch}" \
    --output "${out}" "$@"
}

expect_fail() { # name, then collector args; must exit non-zero AND write nothing
  local name=$1 out="${scratch}/negative.json"
  shift
  rm -f "${out}"
  if run_collector "${out}" "$@" >"${scratch}/neg.out" 2>&1; then
    fail "negative case '${name}' unexpectedly succeeded"
  fi
  [ ! -e "${out}" ] || fail "negative case '${name}' wrote a record anyway"
  echo "ok: fails closed — ${name}"
}

# --- positive -----------------------------------------------------------------
case "${test_os}-${test_arch}" in
  fedora-x64)   expected_machine=x86_64 ;;
  fedora-arm64) expected_machine=aarch64 ;;
  macos-x64)    expected_machine=x86_64 ;;
  macos-arm64)  expected_machine=arm64 ;;
esac
case "${test_os}" in
  fedora) probe_template=.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl ;;
  macos)  probe_template=.chezmoiscripts/20-darwin/run_onchange_before_homebrew.sh.tmpl ;;
esac
run_collector "${scratch}/evidence.json" >/"${scratch}/pos.out" 2>&1 \
  || fail "positive case failed: $(cat "${scratch}/pos.out")"
jq -e \
  --arg device "${test_os}-${test_arch}" \
  --arg os "${test_os}" \
  --arg arch "${test_arch}" \
  --arg commit "${candidate_commit}" \
  --arg snapshot "$(canonical_digest "${scratch}/support-matrix.json")" \
  --arg collector "$(sha256_file "${collector}")" \
  --arg wref "${workflow_ref}" \
  --arg wsha "${workflow_sha}" \
  --arg machine "${expected_machine}" \
  '.schemaVersion == 1
   and .device.id == $device
   and .device.os == $os
   and .device.arch == $arch
   and .device.runnerClass == "github-hosted"
   and .device.runnerLabels == ["github-hosted", $os, $arch]
   and .collector.path == ".ci/collect-device-evidence.sh"
   and .collector.sha256 == $collector
   and .candidate.commit == $commit
   and .supportSnapshot.path == ".ci/support-matrix.json"
   and .supportSnapshot.sha256 == $snapshot
   and .attestation.kind == "github-artifact-attestation"
   and .attestation.issuer == "https://token.actions.githubusercontent.com"
   and .attestation.repository == "example/dotfiles"
   and .attestation.workflowRef == $wref
   and .attestation.workflowSha == $wsha
   and .attestation.environment == "device-evidence"
   and .measurements.runtimeArch == $machine
   and ([.measurements.checks[].name] | sort)
       == ["candidate-commit", "render-smoke", "runtime-arch", "support-snapshot"]
   and (.measurements.checks | all(.status == "pass"))
   and (.collectedAt | type == "string")' \
  "${scratch}/evidence.json" >/dev/null || fail "positive record failed field assertions"
echo "ok: positive record is well-formed and fully bound"

# Exercise the emitted bytes through the repository's schema interpreter after
# a JSON serialize/parse round trip, rather than duplicating schema rules here.
node --input-type=module - \
  "${scratch}/evidence.json" \
  "${repo_root}/.ci/device-evidence.schema.json" \
  "${repo_root}/.ci/validate-device-evidence.mjs" <<'NODE' \
  || fail "positive record failed schema/validator round trip"
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const [evidencePath, schemaPath, validatorPath] = process.argv.slice(2);
const { validateSchema } = await import(pathToFileURL(validatorPath));
const schema = JSON.parse(readFileSync(schemaPath, 'utf8'));
const record = JSON.parse(JSON.stringify(JSON.parse(readFileSync(evidencePath, 'utf8'))));
const errors = validateSchema(record, schema);
if (errors.length) {
  console.error(errors.join('\n'));
  process.exit(1);
}
NODE
echo "ok: positive record survives schema/validator round trip"

# Human-only G1b claims require a proof outside the candidate checkout whose
# identity and check outcome are folded into the attested evidence record.
proof="${scratch}/g1b-proof.json"
jq -n \
  --arg device "${test_os}-${test_arch}" \
  --arg commit "${candidate_commit}" \
  --arg snapshot "$(canonical_digest "${scratch}/support-matrix.json")" \
  '{
    schemaVersion: 1,
    device: {id: $device},
    candidate: {commit: $commit},
    supportSnapshot: {path: ".ci/support-matrix.json", sha256: $snapshot},
    checks: [{name: "inline-image-renders-in-tmux", status: "pass", detail: "operator observed the protected device"}]
  }' >"${proof}"
run_collector "${scratch}/visual-evidence.json" \
  --claim inline-image-renders-in-tmux --proof-file "${proof}" \
  >"${scratch}/visual.out" 2>&1 ||
  fail "bound visual proof was rejected: $(cat "${scratch}/visual.out")"
jq -e '.measurements.checks == [{
  name: "inline-image-renders-in-tmux",
  status: "pass",
  detail: "operator observed the protected device"
}]' "${scratch}/visual-evidence.json" >/dev/null ||
  fail "visual proof was not folded into the evidence record"
echo "ok: bound visual proof is folded into evidence"

jq '.candidate.commit = "0000000000000000000000000000000000000000"' \
  "${proof}" >"${scratch}/wrong-proof.json"
expect_fail "visual proof candidate mismatch" \
  --claim inline-image-renders-in-tmux --proof-file "${scratch}/wrong-proof.json"
expect_fail "missing visual proof" --claim inline-image-renders-in-tmux

# A candidate template is executable during rendering, so prove the child
# cannot observe an ambient credential even when it deliberately probes for it.
credential_candidate="${scratch}/credential-candidate"
mkdir -p "${credential_candidate}/${probe_template%/*}"
cat > "${credential_candidate}/${probe_template}" <<'TMPL'
#!/usr/bin/env bash
{{ if eq (env "GITHUB_TOKEN") "device-evidence-sentinel-credential" }}'{{ end }}
:
TMPL
git -C "${credential_candidate}" init -q
git -C "${credential_candidate}" add "${probe_template}"
git -C "${credential_candidate}" \
  -c user.name=device-evidence -c user.email=device-evidence@example.invalid \
  commit -qm credential-isolation-fixture
candidate_dir=${credential_candidate}
candidate_commit=$(git -C "${candidate_dir}" rev-parse HEAD)
GITHUB_TOKEN=device-evidence-sentinel-credential \
  run_collector "${scratch}/credential-isolation.json" >"${scratch}/credential.out" 2>&1 \
  || fail "candidate template observed injected sentinel credential: $(cat "${scratch}/credential.out")"
echo "ok: render child cannot read injected sentinel credential"

# --- negatives ----------------------------------------------------------------
case "${test_arch}" in
  x64)   wrong_arch=arm64 ;;
  arm64) wrong_arch=x64 ;;
esac
expect_fail "wrong runtime arch" --arch "${wrong_arch}"

expect_fail "candidate commit mismatch" \
  --candidate-commit 0000000000000000000000000000000000000000
expect_fail "missing support snapshot" \
  --support-snapshot "${scratch}/no-such-snapshot.json"
expect_fail "malformed workflow sha" \
  --workflow-sha nothex
expect_fail "unknown claim" \
  --claim candidate-invented-claim
expect_fail "workflow ref outside repository" \
  --workflow-ref "evil/repo/.github/workflows/device-smoke.yml@refs/heads/main"

mkdir -p "${scratch}/not-a-repo"
expect_fail "candidate dir is not a git work tree" --candidate-dir "${scratch}/not-a-repo"

case "${test_os}" in
  fedora) wrong_os=macos ;;
  macos)  wrong_os=fedora ;;
esac
expect_fail "wrong OS identity" --os "${wrong_os}"

echo "test-device-collectors: all fixtures passed (${test_os}/${test_arch})"
