#!/usr/bin/env bash
# Shared render-gate helpers, sourced (never executed directly) by
# .ci/test-fingerprint-gates.sh, .ci/test-agent-instructions.sh and
# .ci/test-sudo-elevation-guard.sh.
#
# Every function takes repo_root, scratch, and chezmoi_bin as leading
# positional arguments instead of reading them from caller-declared globals:
# nothing here is read implicitly, so sourcing this file into a script whose
# globals are named or scoped differently cannot silently break it.
#
# `fail` stays script-local in each caller — its message prefix is the one
# genuine per-script difference, and only `assert_gate` calls it.

require_file() {
  local repo_root=$1 path=$4
  [[ -f "$repo_root/$path" ]] || fail "missing source surface $path"
}

render() {
  local repo_root=$1 scratch=$2 chezmoi_bin=$3 os=$4 input=$5 output=$6
  env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" \
      --destination "$scratch/target" --override-data "{\"chezmoi\":{\"os\":\"$os\"}}" \
      execute-template <"$input" >"$output"
}

# Render the production ignore template with only its fact provider replaced by
# deterministic fixture facts. This exercises the real path gates without
# consulting this runner's container markers or desktop session.
# Rewrite a repo-meta template so the fixture can pin `container`, replacing the
# real fact provider with a literal dict. The dict is built from the `$f.<key>`
# references the template ACTUALLY makes, because a hand-listed subset silently
# omits every fact added later and chezmoi then fails with `map has no entry for
# key` in CI only.
write_fact_stub() {
  local source_path=$1 output_path=$2 container=$3 jetson=${4:-false} desktop=${5:-gnome}
  local stub="dict \"container\" $container \"jetson\" $jetson \"desktop\" \"$desktop\" \"distro\" \"fedora\" \"headless\" false \"nvidia\" false"
  # Two call forms reach facts.tmpl: a top-level template passes `.`, while a
  # shared partial must pass `.ctx` because a partial's `.` is only ever what its
  # caller handed it. Both are matched, so a fixture can pin facts for either.
  # `desktop` is a parameter rather than a constant: the fact is derived from
  # `lookPath` and KDE wins a tie, so a PATH stub cannot produce a `gnome`
  # rendering on a host that has plasmashell — only substitution can.
  sed -e 's|includeTemplate "facts.tmpl" \. \| fromYaml|'"$stub"'|g' \
      -e 's|includeTemplate "facts.tmpl" \.ctx \| fromYaml|'"$stub"'|g' \
      "$source_path" > "$output_path"
}

render_ignore() {
  local repo_root=$1 scratch=$2 chezmoi_bin=$3 os=$4 container=$5 output=$6 jetson=${7:-false} variant
  variant="$scratch/ignore-$os-$container-$jetson.tmpl"
  write_fact_stub "$repo_root/.chezmoiignore" "$variant" "$container" "$jetson"
  render "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$variant" "$output"
}

is_ignored() {
  local rendered=$4 path=${5#./} pattern
  while IFS= read -r pattern; do
    pattern=${pattern#./}
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    # shellcheck disable=SC2053 # The rendered ignore entry is an intentional glob.
    if [[ "$path" == $pattern || "$path" == "$pattern"/* ]]; then
      return 0
    fi
  done <"$rendered"
  return 1
}

assert_gate() {
  local repo_root=$1 scratch=$2 chezmoi_bin=$3 rendered=$4 expected=$5 path=$6 label=$7
  if [[ "$expected" == eligible ]]; then
    if is_ignored "$repo_root" "$scratch" "$chezmoi_bin" "$rendered" "$path"; then fail "$label unexpectedly ignored $path"; fi
  elif ! is_ignored "$repo_root" "$scratch" "$chezmoi_bin" "$rendered" "$path"; then
    fail "$label unexpectedly exposes $path"
  fi
}

render_reconciler() {
  local repo_root=$1 scratch=$2 chezmoi_bin=$3 os=$4 container=$5 template=$6 output=$7 jetson=${8:-false} variant
  variant="$scratch/reconciler-$os-$container-$jetson-$(basename "$template")"
  local stub="dict \"container\" $container \"jetson\" $jetson \"desktop\" \"gnome\" \"distro\" \"fedora\" \"headless\" false \"nvidia\" false"
  sed 's|includeTemplate "facts.tmpl" \. \| fromYaml|'"$stub"'|g' "$repo_root/$template" > "$variant"
  render "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$variant" "$output"
}
