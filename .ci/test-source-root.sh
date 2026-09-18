#!/usr/bin/env bash
# test-source-root.sh -- proves .ci/lib/source-root.sh's indirection: that
# resolve_source_root agrees with chezmoi's own source-directory resolution,
# that require_file/render_ignore classify a path the same way KTD3's
# Appendix does, and that a lint can tell a $repo_root-style join to a
# source-state name from one that already goes through the resolver.
#
# WHY THIS EXISTS. The plan at
# docs/plans/2026-09-18-1112-refactor-chezmoi-source-root-move-plan.md moves
# the chezmoi source state into home/ behind a one-line .chezmoiroot. Every
# .ci script that reads a source-state path today spells it $repo_root/<name>,
# because the source root and the repository root are the same directory.
# Once .chezmoiroot exists that spelling is wrong, silently: a script starts
# reading beside the source state instead of inside it. This gate pins the
# resolver's semantics before anything depends on them, and its lint is what
# would have caught a join nobody repointed.
#
# FOUR PARTS.
#   1. Resolver unit cases: absent marker, present marker (with and without
#      padding), and each refusal (empty, absolute, parent-escaping, missing
#      directory) -- each on its own throwaway scratch tree.
#   2. Parity: resolve_source_root's answer for a root equals what a chezmoi
#      render reports for `.chezmoi.sourceDir` from the same root, for this
#      checkout and for a rooted scratch tree.
#   3. require_file/render_ignore integration on a rooted scratch tree: a
#      source-state path resolves under the tree's source root, and a
#      .ci/fixtures/... path -- repository infrastructure -- stays on the
#      tree's own root even though its home/ carries no .ci of its own at
#      all.
#   4. The lint: a fixture proves it rejects a literal
#      $repo_root/.chezmoidata/... join and accepts the three shapes that
#      must keep working, before it is run for real against this checkout.
#
# ON THAT LAST RUN. It runs for real against this checkout at the very end of
# this script, not just against a fixture, verifying that zero remaining
# $repo_root joins to a source-state name exist across .ci/**/*.sh.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() { printf 'test-source-root: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'test-source-root: ok - %s\n' "$*"; }

# shellcheck source=.ci/lib/render-scratch.sh
source "$repo_root/.ci/lib/render-scratch.sh"
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"

chezmoi_bin=$(command -v chezmoi) || fail 'chezmoi is required on PATH'

setup_render_scratch source-root

# ---------------------------------------------------------------------------
# Part 1 -- resolver unit cases
# ---------------------------------------------------------------------------

flat_root="$scratch/flat-root"
mkdir -p -- "$flat_root"
result=$(resolve_source_root "$flat_root") || fail 'a root without .chezmoiroot must resolve, not fail'
[[ "$result" == "$flat_root" ]] || fail "a root without .chezmoiroot resolved to $result, not itself"
pass 'a root without .chezmoiroot resolves to itself'

rooted_root="$scratch/rooted-root"
mkdir -p -- "$rooted_root/home"
printf 'home\n' >"$rooted_root/.chezmoiroot"
result=$(resolve_source_root "$rooted_root") || fail 'home plus a trailing newline must resolve'
[[ "$result" == "$rooted_root/home" ]] || fail "resolved to $result, not $rooted_root/home"
pass 'a .chezmoiroot holding home plus a trailing newline resolves to <root>/home'

padded_root="$scratch/padded-root"
mkdir -p -- "$padded_root/home"
printf '  home  \n' >"$padded_root/.chezmoiroot"
result=$(resolve_source_root "$padded_root") || fail 'a padded value must resolve'
[[ "$result" == "$padded_root/home" ]] || fail "resolved to $result, not $padded_root/home"
pass 'a .chezmoiroot with surrounding spaces resolves like the trimmed value'

# assert_resolve_fails <label> <root> <diagnostic-substring>
#
# Confirms resolve_source_root refuses <root>, names <root>/.chezmoiroot in
# its diagnostic, and includes <diagnostic-substring>.
assert_resolve_fails() {
  local label=$1 root=$2 want=$3 error
  error=$(resolve_source_root "$root" 2>&1 >/dev/null) && fail "$label: resolve_source_root unexpectedly succeeded: $error"
  grep -qF -- "$root/.chezmoiroot" <<<"$error" || fail "$label: diagnostic did not name $root/.chezmoiroot: $error"
  grep -qF -- "$want" <<<"$error" || fail "$label: diagnostic missing '$want': $error"
  pass "$label"
}

empty_value_root="$scratch/empty-value-root"
mkdir -p -- "$empty_value_root"
: >"$empty_value_root/.chezmoiroot"
assert_resolve_fails 'an empty .chezmoiroot fails naming the file' "$empty_value_root" 'is empty'

absolute_value_root="$scratch/absolute-value-root"
mkdir -p -- "$absolute_value_root"
printf '/etc\n' >"$absolute_value_root/.chezmoiroot"
assert_resolve_fails 'an absolute .chezmoiroot value fails naming the file' "$absolute_value_root" 'absolute path'

escaping_value_root="$scratch/escaping-value-root"
mkdir -p -- "$escaping_value_root"
printf '../etc\n' >"$escaping_value_root/.chezmoiroot"
assert_resolve_fails 'a .chezmoiroot value containing .. fails naming the file' "$escaping_value_root" 'escapes its parent'

missing_dir_root="$scratch/missing-dir-root"
mkdir -p -- "$missing_dir_root"
printf 'nonexistent\n' >"$missing_dir_root/.chezmoiroot"
assert_resolve_fails 'a .chezmoiroot naming a directory that does not exist fails' "$missing_dir_root" 'does not exist'

# ---------------------------------------------------------------------------
# Part 1b -- is_source_state_segment unit cases
# ---------------------------------------------------------------------------

for seg in dot_x private_x symlink_x remove_x \
    .chezmoi.toml.tmpl .chezmoidata .chezmoiexternals .chezmoiignore \
    .chezmoiremove .chezmoiscripts .chezmoitemplates .keys Library; do
  is_source_state_segment "$seg" || fail "is_source_state_segment unexpectedly returned 1 for $seg"
done
pass 'is_source_state_segment returns 0 for source-state prefix patterns and exact names'

for seg in packages .ci .chezmoiroot mise.toml dotfile; do
  if is_source_state_segment "$seg"; then
    fail "is_source_state_segment unexpectedly returned 0 for $seg"
  fi
done
pass 'is_source_state_segment returns 1 for non-source-state names'

# ---------------------------------------------------------------------------
# Part 2 -- parity with chezmoi's own .chezmoi.sourceDir
# ---------------------------------------------------------------------------

source_dir_tmpl="$scratch/source-dir.tmpl"
printf '{{ .chezmoi.sourceDir }}' >"$source_dir_tmpl"

# assert_parity <label> <root>
#
# Renders {{ .chezmoi.sourceDir }} with --source <root> under the render
# contract and confirms it equals resolve_source_root <root>.
_parity_seq=0
assert_parity() {
  local label=$1 root=$2 rendered resolved reported
  _parity_seq=$((_parity_seq + 1))
  rendered="$scratch/parity-$_parity_seq.out"
  resolved=$(resolve_source_root "$root") || fail "$label: resolve_source_root failed unexpectedly"
  render "$root" "$scratch" "$chezmoi_bin" linux "$source_dir_tmpl" "$rendered" || fail "$label: render failed"
  reported=$(<"$rendered")
  [[ "$reported" == "$resolved" ]] || fail "$label: resolver says $resolved, chezmoi's sourceDir says $reported"
  pass "$label"
}

assert_parity 'for this checkout, resolve_source_root matches chezmoi.sourceDir' "$repo_root"

parity_rooted="$scratch/parity-rooted"
mkdir -p -- "$parity_rooted/home"
printf 'home\n' >"$parity_rooted/.chezmoiroot"
assert_parity 'parity holds for a rooted scratch tree as well' "$parity_rooted"

# ---------------------------------------------------------------------------
# Part 3 -- require_file / render_ignore integration on a rooted scratch tree
# ---------------------------------------------------------------------------

integration_root="$scratch/integration-root"
mkdir -p -- "$integration_root/home/.chezmoidata"
printf 'home\n' >"$integration_root/.chezmoiroot"
printf 'placeholder: true\n' >"$integration_root/home/.chezmoidata/placeholder.yaml"
printf 'placeholder-ignore/\n' >"$integration_root/home/.chezmoiignore"

require_file "$integration_root" "$scratch" "$chezmoi_bin" .chezmoidata/placeholder.yaml
pass 'require_file accepts a source-state path in a rooted scratch tree'

rooted_ignore_out="$scratch/rooted-ignore.txt"
render_ignore "$integration_root" "$scratch" "$chezmoi_bin" linux false "$rooted_ignore_out"
grep -qF 'placeholder-ignore/' "$rooted_ignore_out" || fail "render_ignore did not render the rooted tree's own .chezmoiignore"
pass "render_ignore renders a rooted scratch tree's ignore file"

# .ci/test-agent-instructions.sh calls require_file with exactly this shape of
# path -- a .ci/fixtures/agent-instructions/... argument -- to require its
# committed comparison fixtures. Those fixtures live at the repository root
# today and stay there after the move (KTD3's Appendix keeps .ci repository
# infrastructure), so require_file must resolve this path against the tree's
# own root rather than its source root. Proven here on a tree whose home/
# holds no .ci of its own at all, so a wrong join would fail loudly rather
# than accidentally succeed against a stray copy.
fixtures_root="$scratch/fixtures-root"
mkdir -p -- "$fixtures_root/home" "$fixtures_root/.ci/fixtures/agent-instructions"
printf 'home\n' >"$fixtures_root/.chezmoiroot"
printf 'fixture body\n' >"$fixtures_root/.ci/fixtures/agent-instructions/dummy.txt"
[[ -d "$fixtures_root/home/.ci" ]] && fail 'test setup error: home/.ci must not exist for this scenario'

require_file "$fixtures_root" "$scratch" "$chezmoi_bin" .ci/fixtures/agent-instructions/dummy.txt
pass 'require_file accepts a .ci/fixtures/agent-instructions/ path in a rooted scratch tree whose home/ has no .ci'

# ---------------------------------------------------------------------------
# Part 3b -- populate_fixture_source_root unit cases
# ---------------------------------------------------------------------------

pop_parent="$scratch/pop-fixture-parent"
mkdir -p -- "$pop_parent"

pop_source="$scratch/pop-source"
mkdir -p -- "$pop_source"
touch "$pop_source/entry_a" "$pop_source/entry_b"

# Flat fixture fallback (Item 5): when .chezmoiroot is absent,
# populate_fixture_source_root prints the fixture directory itself and creates nothing.
flat_fixture="$pop_parent/flat-fixture"
mkdir -p -- "$flat_fixture"
flat_pop_out=$(populate_fixture_source_root "$flat_fixture" "$pop_source") ||
  fail 'populate_fixture_source_root unexpectedly failed for a flat fixture'
[[ "$flat_pop_out" == "$flat_fixture" ]] ||
  fail "populate_fixture_source_root printed $flat_pop_out, expected $flat_fixture"
flat_entries=("$flat_fixture"/* "$flat_fixture"/.[!.]*)
for e in "${flat_entries[@]}"; do
  [[ -e "$e" ]] && fail "populate_fixture_source_root created $e in flat fixture"
done
pass 'populate_fixture_source_root prints the fixture directory itself and creates nothing when .chezmoiroot is absent'

# Resolver failure on absolute .chezmoiroot (Item 3): makes populate_fixture_source_root
# fail, and nothing is created outside the fixture.
abs_fixture="$pop_parent/abs-fixture"
mkdir -p -- "$abs_fixture"
printf '/etc\n' >"$abs_fixture/.chezmoiroot"

abs_err=$(populate_fixture_source_root "$abs_fixture" "$pop_source" 2>&1) &&
  fail 'populate_fixture_source_root unexpectedly succeeded for a fixture with absolute .chezmoiroot'
grep -qF -- "$abs_fixture" <<<"$abs_err" ||
  fail "populate_fixture_source_root error did not name fixture $abs_fixture: $abs_err"

# Confirm no new entry appeared in the fixture's parent
parent_entries=("$pop_parent"/*)
for e in "${parent_entries[@]}"; do
  [[ "$e" == "$flat_fixture" || "$e" == "$abs_fixture" ]] ||
    fail "unexpected entry created in fixture parent: $e"
done
# Check that scratch area has no leaked symlinks
for e in "$scratch"/* "$scratch"/.[!.]*; do
  [[ -e "$e" ]] || continue
  base=$(basename -- "$e")
  [[ "$base" != "entry_a" && "$base" != "entry_b" ]] ||
    fail "populate_fixture_source_root leaked symlink $base into scratch"
done
[[ ! -e "/entry_a" && ! -e "/entry_b" ]] ||
  fail 'populate_fixture_source_root leaked symlinks to the filesystem root'
pass 'populate_fixture_source_root fails on absolute .chezmoiroot and creates nothing outside the fixture'

# ---------------------------------------------------------------------------
# Part 4 -- the lint: a $repo_root-style join to a source-state name
# ---------------------------------------------------------------------------

# lint_source_state_joins <root> <exclude-relative-path> <report-file>
#
# Scans every .ci/**/*.sh file under <root> (skipping comment-only lines and
# <exclude-relative-path>) for SOURCE_ROOT_JOIN_PATTERN, writing each
# offending "<relative-path>:<line>:<content>" to <report-file>. Returns 0
# (report left empty) when nothing matches, 1 otherwise.
lint_source_state_joins() {
  local root=$1 exclude=$2 report=$3 file rel lineno content trimmed
  : >"$report"
  while IFS=: read -r file lineno content; do
    [[ -n "$file" && -n "$lineno" ]] || continue
    rel=${file#"$root/"}
    [[ "$rel" == "$exclude" ]] && continue
    trimmed="${content#"${content%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] && continue
    printf '%s:%s:%s\n' "$rel" "$lineno" "$content" >>"$report"
  done < <(grep -rnE "$SOURCE_ROOT_JOIN_PATTERN" --include='*.sh' "$root/.ci" || true)
  [[ ! -s "$report" ]]
}

# A tiny wired tree the mutant and negative-control cases mutate, mirroring
# .ci/test-ci-wiring.sh's own fixture discipline: prove the lint would notice
# before trusting a green run of it.
lint_fixture() {
  local tree="$scratch/lint-fixture-$1"
  mkdir -p -- "$tree/.ci"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$tree/.ci/test-fixture.sh"
  printf '%s' "$tree"
}

mutant_tree=$(lint_fixture mutant)
mutant_report="$scratch/lint-mutant.report"
lint_source_state_joins "$mutant_tree" no-such-file.sh "$mutant_report" ||
  fail "a freshly wired fixture unexpectedly reported a violation: $(tr '\n' ';' <"$mutant_report")"
pass 'lint: a fixture with no source-state join passes before the mutant lands'

printf 'read_registry() {\n  cat "$repo_root/.chezmoidata/facts.yaml"\n}\n' >>"$mutant_tree/.ci/test-fixture.sh"
lint_source_state_joins "$mutant_tree" no-such-file.sh "$mutant_report" &&
  fail 'the mutant join was accepted; the lint does not detect it'
grep -qF '$repo_root/.chezmoidata/facts.yaml' "$mutant_report" ||
  fail "the mutant was rejected for the wrong reason: $(tr '\n' ';' <"$mutant_report")"
pass 'lint mutant: a fixture script joining $repo_root/.chezmoidata/facts.yaml is rejected, with the offending line named'

for prefix in dot_x private_x symlink_x remove_x; do
  p_tree=$(lint_fixture "mutant-$prefix")
  p_report="$scratch/lint-mutant-$prefix.report"
  printf 'read_%s() {\n  cat "$repo_root/%s"\n}\n' "$prefix" "$prefix" >>"$p_tree/.ci/test-fixture.sh"
  lint_source_state_joins "$p_tree" no-such-file.sh "$p_report" &&
    fail "the mutant join \$repo_root/$prefix was accepted; the lint does not detect it"
  grep -qF "\$repo_root/$prefix" "$p_report" ||
    fail "the mutant $prefix was rejected for the wrong reason: $(tr '\n' ';' <"$p_report")"
  pass "lint mutant: a fixture script joining \$repo_root/$prefix is rejected, with the offending line named"
done

negative_tree=$(lint_fixture negative)
cat >>"$negative_tree/.ci/test-fixture.sh" <<'EOF'
read_packages() { cat "$repo_root/packages/x"; }
read_lib() { cat "$repo_root/.ci/lib/bun.sh"; }
read_marker() { cat "$repo_root/.chezmoiroot"; }
EOF
negative_report="$scratch/lint-negative.report"
lint_source_state_joins "$negative_tree" no-such-file.sh "$negative_report" ||
  fail "a join to packages/, .ci/lib/, or .chezmoiroot was rejected: $(tr '\n' ';' <"$negative_report")"
pass 'lint negative control: joins to $repo_root/packages/x, $repo_root/.ci/lib/bun.sh, and $repo_root/.chezmoiroot are each accepted'

exclusion_tree=$(lint_fixture excluded)
printf 'read_data() { cat "$repo_root/.chezmoidata/facts.yaml"; }\n' >>"$exclusion_tree/.ci/test-fixture.sh"
exclusion_report="$scratch/lint-excluded.report"
lint_source_state_joins "$exclusion_tree" .ci/test-fixture.sh "$exclusion_report" ||
  fail 'excluding the only offending file should leave the lint clean'
pass 'lint: an excluded file is never scanned, even when it is the only offender'

# ---------------------------------------------------------------------------
# Part 5 -- the real lint, run against this checkout
# ---------------------------------------------------------------------------
#
# This is the production check, not a fixture: it runs for real against the
# repository this script lives in, verifying that all .ci files resolve
# source-state paths via resolve_source_root or join_source_state.
real_report="$scratch/real-lint.report"
if lint_source_state_joins "$repo_root" .ci/test-source-root.sh "$real_report"; then
  pass 'lint: this checkout has zero remaining $repo_root joins to a source-state name'
else
  violating_files=$(cut -d: -f1 "$real_report" | sort -u | wc -l | tr -d ' ')
  violating_lines=$(wc -l <"$real_report" | tr -d ' ')
  printf 'test-source-root: the lint found %s $repo_root-style join(s) across %s file(s):\n' \
    "$violating_lines" "$violating_files" >&2
  sed 's/^/  /' "$real_report" >&2
  fail "$violating_files .ci file(s) still join a source-state name onto \$repo_root; source-state paths must be resolved via resolve_source_root or join_source_state"
fi

printf 'test-source-root: all scenarios passed\n'
