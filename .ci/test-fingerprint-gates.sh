#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/fingerprint-gates.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/target" "$scratch/bin" \
  "$scratch/source/.chezmoitemplates" "$scratch/source/fixtures/only-directory" \
  "$scratch/rooted/home/.chezmoitemplates" "$scratch/rooted/system/linux/etc"
printf '[data]\n' >"$scratch/empty.toml"
printf 'matching fixture\n' >"$scratch/source/fixtures/matching.txt"
# Rooted fixture (KTD1/AE6): a `.chezmoiroot` at the fixture's repository root
# naming `home`, mirroring the Phase B layout `rooted-rehearsal.sh` builds --
# a cross-root glob's base must resolve to the fixture's repository root, not
# to `home`, once the source state moves under it.
printf 'home\n' >"$scratch/rooted/.chezmoiroot"
printf 'sample override\n' >"$scratch/rooted/system/linux/etc/sample.conf"
chezmoi_bin=$(type -P chezmoi) || {
  printf 'fingerprint gates: chezmoi is required\n' >&2
  exit 1
}

fail() { printf 'fingerprint gates: %s\n' "$*" >&2; exit 1; }
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
source_root=$(resolve_source_root "$repo_root")

require_file "$repo_root" "$scratch" "$chezmoi_bin" .chezmoitemplates/fingerprint.tmpl
require_file "$repo_root" "$scratch" "$chezmoi_bin" .chezmoitemplates/repo-root.tmpl
# The fixture source tree dereferences the production partial on every render;
# its inline consumers only supply data and never duplicate fingerprint logic.
ln -s "$source_root/.chezmoitemplates/fingerprint.tmpl" \
  "$scratch/source/.chezmoitemplates/fingerprint.tmpl"
ln -s "$source_root/.chezmoitemplates/repo-root.tmpl" \
  "$scratch/source/.chezmoitemplates/repo-root.tmpl"
ln -s "$source_root/.chezmoitemplates/fingerprint.tmpl" \
  "$scratch/rooted/home/.chezmoitemplates/fingerprint.tmpl"
ln -s "$source_root/.chezmoitemplates/repo-root.tmpl" \
  "$scratch/rooted/home/.chezmoitemplates/repo-root.tmpl"

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

# Exact-match variant of assert_render_ok: a substring check (grep -F) cannot
# tell "$scratch/rooted" apart from "$scratch/rooted/home" -- the shorter path
# is a literal substring of the longer one -- so repo-root.tmpl's parent-vs-self
# choice needs the rendered value compared for equality, not containment.
assert_render_exact() {
  local label=$1 source_root=$2 input=$3 expected=$4
  local output="$scratch/$label.out" error="$scratch/$label.err" actual
  render "$source_root" "$scratch" "$chezmoi_bin" linux "$input" "$output" 2>"$error" || {
    printf 'render-exact %s: expected a successful render, got a failure\n' "$label" >&2
    sed 's/^/  /' "$error" >&2
    exit 1
  }
  actual=$(<"$output")
  [[ "$actual" == "$expected" ]] || {
    printf 'render-exact %s: expected %q, got %q\n' "$label" "$expected" "$actual" >&2
    exit 1
  }
}

# render() against the rooted fixture's repository root, so chezmoi descends
# through its `.chezmoiroot` into home/ on its own -- the same auto-descent a
# real `--source "$repo_root"` gets once Phase B lands `.chezmoiroot`.
render_rooted() {
  local input=$1 output=$2
  shift 2
  render "$scratch/rooted" "$scratch" "$chezmoi_bin" linux "$input" "$output" "$@"
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

# KTD1 -- .chezmoitemplates/repo-root.tmpl: the template-time repository root.
cat >"$scratch/repo-root.tmpl" <<'EOF'
{{- includeTemplate "repo-root.tmpl" .chezmoi.sourceDir -}}
EOF
assert_render_exact repo-root-flat "$scratch/source" "$scratch/repo-root.tmpl" \
  "$scratch/source"
assert_render_exact repo-root-rooted "$scratch/rooted" "$scratch/repo-root.tmpl" \
  "$scratch/rooted"

# AE6 -- the partial is load-bearing, not decorative: in a rooted tree, a
# fingerprint call based straight on .chezmoi.sourceDir cannot see a
# repository-rooted system/... glob (it now lives one level up, outside
# home/), and fails with the zero-match diagnostic; the same call rebased
# through repo-root.tmpl sees it and succeeds.
cat >"$scratch/ae6-sourcedir.tmpl" <<'EOF'
{{ includeTemplate "fingerprint.tmpl" (dict "sourceDir" .chezmoi.sourceDir "globs" (list "system/linux/etc/sample.conf")) }}
EOF
cat >"$scratch/ae6-reporoot.tmpl" <<'EOF'
{{- $repoRoot := includeTemplate "repo-root.tmpl" .chezmoi.sourceDir -}}
{{ includeTemplate "fingerprint.tmpl" (dict "sourceDir" $repoRoot "globs" (list "system/linux/etc/sample.conf")) }}
EOF
ae6_sourcedir_out="$scratch/ae6-sourcedir.out" ae6_sourcedir_err="$scratch/ae6-sourcedir.err"
if render_rooted "$scratch/ae6-sourcedir.tmpl" "$ae6_sourcedir_out" 2>"$ae6_sourcedir_err"; then
  fail "AE6: a bare .chezmoi.sourceDir base unexpectedly rendered a rooted cross-root glob"
fi
grep -qF -e "glob pattern 'system/linux/etc/sample.conf' matched zero files" -- "$ae6_sourcedir_err" || {
  printf 'AE6 red case: render failed without the expected zero-match diagnostic\n' >&2
  sed 's/^/  /' "$ae6_sourcedir_err" >&2
  exit 1
}
assert_render_ok ae6-reporoot "$scratch/rooted" "$scratch/ae6-reporoot.tmpl" \
  '#   system/linux/etc/sample.conf'

production_consumer=.chezmoiscripts/30-linux/run_onchange_after_install-system-10-desktop.sh.tmpl
require_file "$repo_root" "$scratch" "$chezmoi_bin" "$production_consumer"
assert_render_ok production-globs-consumer "$repo_root" "$repo_root/$production_consumer" \
  '#   system/linux/etc/locale.conf'

# Position-independent script rendering (PISR):
# Rendered scripts must not leak the absolute source directory path into executable bodies.
if grep -qF -e "$repo_root" "$scratch/production-globs-consumer.out"; then
  fail "rendered script leaked source root literal $repo_root"
fi

# KTD1's two deployed command sources: their baked path is a TEMPLATE-TIME
# expression (the command is staged into ~/.local/bin and cannot discover the
# source tree at run time), so it goes through $repoRoot like every other
# cross-root site. Today (no `.chezmoiroot`) $repoRoot == .chezmoi.sourceDir,
# so the baked absolute path is unchanged from before this unit.
host_facts_source=dot_local/share/chezmoi-command-sources/executable_host-facts.tmpl
require_file "$repo_root" "$scratch" "$chezmoi_bin" "$host_facts_source"
assert_render_ok host-facts-baked-path "$repo_root" "$repo_root/$host_facts_source" \
  "SRC_ROOT=\"$repo_root/system/linux\""

gem80_firmware_source=dot_local/share/chezmoi-command-sources/executable_gem80-firmware.tmpl
require_file "$repo_root" "$scratch" "$chezmoi_bin" "$gem80_firmware_source"
assert_render_ok gem80-firmware-baked-path "$repo_root" "$repo_root/$gem80_firmware_source" \
  "SOURCE_DIR=\"$repo_root\""

for template in "$source_root"/.chezmoiscripts/30-linux/run_onchange_after_install-system-*.sh.tmpl; do
  [[ -f "$template" ]] || continue
  if grep -q 'SRC_ROOT=' "$template"; then
    grep -q 'SRC_ROOT="\${CHEZMOI_SOURCE_DIR:-' "$template" || \
      fail "template $(basename "$template") does not use position-independent SRC_ROOT resolution"
  fi
done

for template in "$source_root"/.chezmoiscripts/60-build/run_onchange_after_*.sh.tmpl \
                "$source_root"/.chezmoiscripts/00-tools/run_onchange_after_*.sh.tmpl; do
  [[ -f "$template" ]] || continue
  if grep -q '^[[:space:]]*SRC=' "$template"; then
    grep -q 'SRC="\${CHEZMOI_SOURCE_DIR:-' "$template" || \
      fail "template $(basename "$template") does not use position-independent SRC resolution"
  fi
done

grep -q 'config="\${CHEZMOI_SOURCE_DIR:-' "$source_root/.chezmoiscripts/00-tools/run_once_before_mise-trust.sh.tmpl" || \
  fail "run_once_before_mise-trust.sh.tmpl does not use position-independent config resolution"

# The two loops above glob the phases that held a source-path assignment when the
# PISR fix landed, so a new script in any other phase escaped the gate. This one
# is keyed by lifecycle instead: every rerun class chezmoi decides from rendered
# text is scanned, whatever phase it sits in.
while IFS= read -r template; do
  grep -q '^[[:space:]]*SRC_DIR=' "$template" || continue
  grep -q 'SRC_DIR="\${CHEZMOI_SOURCE_DIR:-' "$template" || \
    fail "template $(basename "$template") does not use position-independent SRC_DIR resolution"
done < <(find "$source_root/.chezmoiscripts" -type f \
  \( -name 'run_onchange_*.sh.tmpl' -o -name 'run_once_*.sh.tmpl' \))

printf '%s\n' 'fingerprint render gates passed'
