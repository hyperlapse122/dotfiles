#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/fingerprint-gates.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/target" "$scratch/bin" \
  "$scratch/source/.chezmoitemplates" "$scratch/source/fixtures/only-directory"
printf '[data]\n' >"$scratch/empty.toml"
printf 'matching fixture\n' >"$scratch/source/fixtures/matching.txt"
chezmoi_bin=$(type -P chezmoi) || {
  printf 'fingerprint gates: chezmoi is required\n' >&2
  exit 1
}

fail() { printf 'fingerprint gates: %s\n' "$*" >&2; exit 1; }
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"

require_file "$repo_root" "$scratch" "$chezmoi_bin" .chezmoitemplates/fingerprint.tmpl
# The fixture source tree dereferences the production partial on every render;
# its inline consumers only supply data and never duplicate fingerprint logic.
ln -s "$repo_root/.chezmoitemplates/fingerprint.tmpl" \
  "$scratch/source/.chezmoitemplates/fingerprint.tmpl"

assert_render_ok() {
  local label=$1 source_root=$2 input=$3 expected=$4
  local output="$scratch/$label.out" error="$scratch/$label.err"
  render "$source_root" "$scratch" "$chezmoi_bin" linux "$input" "$output" 2>"$error" || {
    printf 'render-positive %s: expected a successful render, got a failure\n' "$label" >&2
    sed 's/^/  /' "$error" >&2
    exit 1
  }
  grep -qF -e "$expected" -- "$output" || {
    printf 'render-positive %s: rendered output omitted %s\n' "$label" "$expected" >&2
    sed 's/^/  /' "$output" >&2
    exit 1
  }
}

assert_partial_fails() {
  local label=$1 input=$2
  shift 2
  local output="$scratch/$label.out" error="$scratch/$label.err" expected
  if render "$scratch/source" "$scratch" "$chezmoi_bin" linux "$input" "$output" 2>"$error"; then
    printf 'render-partial %s: expected a failed render, got exit 0\n' "$label" >&2
    exit 1
  fi
  for expected in "$@"; do
    grep -qF -e "$expected" -- "$error" || {
      printf 'render-partial %s: render failed without the expected diagnostic %s\n' "$label" "$expected" >&2
      sed 's/^/  /' "$error" >&2
      exit 1
    }
  done
}

cat >"$scratch/matching.tmpl" <<'EOF'
{{ includeTemplate "fingerprint.tmpl" (dict "sourceDir" .chezmoi.sourceDir "globs" (list "fixtures/matching.txt")) }}
EOF
cat >"$scratch/zero-match.tmpl" <<'EOF'
{{ includeTemplate "fingerprint.tmpl" (dict "sourceDir" .chezmoi.sourceDir "globs" (list "fixtures/absent.*")) }}
EOF
cat >"$scratch/directory-only.tmpl" <<'EOF'
{{ includeTemplate "fingerprint.tmpl" (dict "sourceDir" .chezmoi.sourceDir "globs" (list "fixtures/only-directory")) }}
EOF
cat >"$scratch/values-only.tmpl" <<'EOF'
{{ includeTemplate "fingerprint.tmpl" (dict "sourceDir" .chezmoi.sourceDir "values" (list (dict "name" "fixture-token" "value" "available"))) }}
EOF
cat >"$scratch/neither.tmpl" <<'EOF'
{{ includeTemplate "fingerprint.tmpl" (dict "sourceDir" .chezmoi.sourceDir) }}
EOF

assert_render_ok matching-regular-file "$scratch/source" "$scratch/matching.tmpl" \
  '#   fixtures/matching.txt  '
assert_partial_fails zero-match "$scratch/zero-match.tmpl" \
  "glob pattern 'fixtures/absent.*' matched zero files" "$scratch/source"
assert_partial_fails directory-only "$scratch/directory-only.tmpl" \
  "glob pattern 'fixtures/only-directory' matched zero files" "$scratch/source"
assert_render_ok values-only "$scratch/source" "$scratch/values-only.tmpl" \
  '#   value:fixture-token  '
assert_partial_fails neither "$scratch/neither.tmpl" \
  'fingerprint.tmpl: called with neither "globs" nor "values"' "$scratch/source"

production_consumer=.chezmoiscripts/30-linux/run_onchange_after_install-system-10-desktop.sh.tmpl
require_file "$repo_root" "$scratch" "$chezmoi_bin" "$production_consumer"
assert_render_ok production-globs-consumer "$repo_root" "$repo_root/$production_consumer" \
  '#   system/linux/etc/locale.conf'

printf '%s\n' 'fingerprint render gates passed'
