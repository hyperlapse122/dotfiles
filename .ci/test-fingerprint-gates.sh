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
require_file "$repo_root" "$scratch" "$chezmoi_bin" .chezmoitemplates/repo-root.sh.tmpl
# The fixture source tree dereferences the production partial on every render;
# its inline consumers only supply data and never duplicate fingerprint logic.
ln -s "$source_root/.chezmoitemplates/fingerprint.tmpl" \
  "$scratch/source/.chezmoitemplates/fingerprint.tmpl"
ln -s "$source_root/.chezmoitemplates/repo-root.tmpl" \
  "$scratch/source/.chezmoitemplates/repo-root.tmpl"
ln -s "$source_root/.chezmoitemplates/repo-root.sh.tmpl" \
  "$scratch/source/.chezmoitemplates/repo-root.sh.tmpl"
ln -s "$source_root/.chezmoitemplates/fingerprint.tmpl" \
  "$scratch/rooted/home/.chezmoitemplates/fingerprint.tmpl"
ln -s "$source_root/.chezmoitemplates/repo-root.tmpl" \
  "$scratch/rooted/home/.chezmoitemplates/repo-root.tmpl"
ln -s "$source_root/.chezmoitemplates/repo-root.sh.tmpl" \
  "$scratch/rooted/home/.chezmoitemplates/repo-root.sh.tmpl"

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

# Scenario 1: The rendered partial contains no absolute path and no checkout-specific literal.
printf '{{ includeTemplate "repo-root.sh.tmpl" | trim }}\n' >"$scratch/runtime-repo-root-partial.tmpl"
assert_render_ok runtime-repo-root-partial "$scratch/source" "$scratch/runtime-repo-root-partial.tmpl" \
  'repo_root='
if grep -qF -e "$repo_root" "$scratch/runtime-repo-root-partial.out"; then
  fail "rendered runtime repo-root partial leaked repository root literal $repo_root"
fi

# Standalone execution tests for scenarios 2–5:
# Extract the rendered partial into a standalone scratch script and execute only that.
runtime_snippet_sh="$scratch/runtime-repo-root.sh"
cp "$scratch/runtime-repo-root-partial.out" "$runtime_snippet_sh"
printf '\nprintf "%%s" "$repo_root"\n' >>"$runtime_snippet_sh"

# Scenario 2: Executed with CHEZMOI_SOURCE_DIR set to a flat scratch source, yields that directory.
actual_flat=$(env CHEZMOI_SOURCE_DIR="$scratch/source" bash "$runtime_snippet_sh")
if [[ "$actual_flat" != "$scratch/source" ]]; then
  fail "runtime repo-root flat scratch expected $scratch/source, got $actual_flat"
fi

# Scenario 3: Executed with CHEZMOI_SOURCE_DIR set to a rooted scratch source's home/, yields scratch root.
actual_rooted=$(env CHEZMOI_SOURCE_DIR="$scratch/rooted/home" bash "$runtime_snippet_sh")
if [[ "$actual_rooted" != "$scratch/rooted" ]]; then
  fail "runtime repo-root rooted scratch expected $scratch/rooted, got $actual_rooted"
fi
actual_rooted_slash=$(env CHEZMOI_SOURCE_DIR="$scratch/rooted/home/" bash "$runtime_snippet_sh")
if [[ "$actual_rooted_slash" != "$scratch/rooted" ]]; then
  fail "runtime repo-root rooted scratch (trailing slash) expected $scratch/rooted, got $actual_rooted_slash"
fi

# Scenario 4: Executed with CHEZMOI_SOURCE_DIR unset and stub chezmoi on PATH, yields root.
mkdir -p "$scratch/stub-bin"
cat >"$scratch/stub-bin/chezmoi" <<EOF
#!/bin/sh
if [ "\$1" = "source-path" ]; then
  printf '%s\n' "$scratch/rooted/home"
fi
EOF
chmod +x "$scratch/stub-bin/chezmoi"
actual_stub=$(env -u CHEZMOI_SOURCE_DIR PATH="$scratch/stub-bin:/usr/bin:/bin" bash "$runtime_snippet_sh")
if [[ "$actual_stub" != "$scratch/rooted" ]]; then
  fail "runtime repo-root stub chezmoi expected $scratch/rooted, got $actual_stub"
fi

# Scenario 5: Executed with neither (CHEZMOI_SOURCE_DIR unset, no chezmoi on PATH), yields working directory.
mkdir -p "$scratch/no-chezmoi-bin"
for tool in bash pwd test [ printf sh; do
  tool_path=$(type -P "$tool" 2>/dev/null || true)
  if [[ -n "$tool_path" ]]; then
    ln -sf "$tool_path" "$scratch/no-chezmoi-bin/$tool"
  fi
done
mkdir -p "$scratch/isolated-workdir"
actual_neither=$(cd "$scratch/isolated-workdir" && env -u CHEZMOI_SOURCE_DIR PATH="$scratch/no-chezmoi-bin" bash "$runtime_snippet_sh")
if [[ "$actual_neither" != "$scratch/isolated-workdir" ]]; then
  fail "runtime repo-root fallback to pwd expected $scratch/isolated-workdir, got $actual_neither"
fi

# Scenario 6: Every one of the 17 templates includes the partial and assigns its path variable from $repo_root;
# a fixture template with the old inline spelling is rejected by the rewritten assertion.
verified_template_count=0

for template in "$source_root"/.chezmoiscripts/30-linux/run_onchange_after_install-system-*.sh.tmpl; do
  [[ -f "$template" ]] || continue
  if grep -q 'SRC_ROOT=' "$template"; then
    if ! grep -q 'includeTemplate "repo-root.sh.tmpl"' "$template" || \
       ! grep -q 'SRC_ROOT="\$repo_root' "$template"; then
      fail "template $(basename "$template") does not use position-independent SRC_ROOT resolution via repo-root.sh.tmpl"
    fi
    verified_template_count=$((verified_template_count + 1))
  fi
done

for template in "$source_root"/.chezmoiscripts/60-build/run_onchange_after_*.sh.tmpl \
                "$source_root"/.chezmoiscripts/00-tools/run_onchange_after_*.sh.tmpl; do
  [[ -f "$template" ]] || continue
  if grep -q '^[[:space:]]*SRC=' "$template"; then
    if ! grep -q 'includeTemplate "repo-root.sh.tmpl"' "$template" || \
       ! grep -q 'SRC="\$repo_root' "$template"; then
      fail "template $(basename "$template") does not use position-independent SRC resolution via repo-root.sh.tmpl"
    fi
    verified_template_count=$((verified_template_count + 1))
  fi
done

mise_trust_template="$source_root/.chezmoiscripts/00-tools/run_once_before_mise-trust.sh.tmpl"
if ! grep -q 'includeTemplate "repo-root.sh.tmpl"' "$mise_trust_template" || \
   ! grep -q 'config="\$repo_root' "$mise_trust_template"; then
  fail "run_once_before_mise-trust.sh.tmpl does not use position-independent config resolution via repo-root.sh.tmpl"
fi
verified_template_count=$((verified_template_count + 1))

while IFS= read -r template; do
  grep -q '^[[:space:]]*SRC_DIR=' "$template" || continue
  if ! grep -q 'includeTemplate "repo-root.sh.tmpl"' "$template" || \
     ! grep -q 'SRC_DIR="\$repo_root' "$template"; then
    fail "template $(basename "$template") does not use position-independent SRC_DIR resolution via repo-root.sh.tmpl"
  fi
  verified_template_count=$((verified_template_count + 1))
done < <(find "$source_root/.chezmoiscripts" -type f \
  \( -name 'run_onchange_*.sh.tmpl' -o -name 'run_once_*.sh.tmpl' \))

if [[ "$verified_template_count" -ne 17 ]]; then
  fail "expected 17 templates to be verified for runtime repo-root resolution, got $verified_template_count"
fi

# Mutant detection (scenario 6):
# A fixture template using the old inline CHEZMOI_SOURCE_DIR resolution must be rejected
# by the assertion logic.
mutant_template="$scratch/mutant-old-inline.sh.tmpl"
cat >"$mutant_template" <<'EOF'
SRC_ROOT="${CHEZMOI_SOURCE_DIR:-$(if command -v chezmoi >/dev/null 2>&1; then chezmoi source-path; else pwd; fi)}/system/linux"
EOF

mutant_rejected=0
if grep -q 'SRC_ROOT=' "$mutant_template"; then
  if ! grep -q 'includeTemplate "repo-root.sh.tmpl"' "$mutant_template" || \
     ! grep -q 'SRC_ROOT="\$repo_root' "$mutant_template"; then
    mutant_rejected=1
  fi
fi
if [[ "$mutant_rejected" -ne 1 ]]; then
  fail "mutant fixture with old inline spelling was unexpectedly accepted"
fi
printf '%s\n' 'fingerprint render gates passed'
