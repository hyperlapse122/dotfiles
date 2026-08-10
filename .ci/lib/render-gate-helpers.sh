#!/usr/bin/env bash
# Shared render-gate helpers, sourced (never executed directly) by
# .ci/test-mxm4-haptic-gates.sh.
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
render_ignore() {
  local repo_root=$1 scratch=$2 chezmoi_bin=$3 os=$4 container=$5 output=$6 variant
  variant="$scratch/ignore-$os-$container.tmpl"
  node -e '
    const fs = require("node:fs");
    const [sourcePath, outputPath, container] = process.argv.slice(1);
    const source = fs.readFileSync(sourcePath, "utf8");
    const needle = `{{- $f := includeTemplate "facts.tmpl" . | fromYaml }}`;
    const replacement = `{{- $f := dict "container" ${container} "desktop" "gnome" "distro" "fedora" "headless" false }}`;
    if (source.split(needle).length !== 2) throw new Error("facts provider anchor changed");
    fs.writeFileSync(outputPath, source.replace(needle, replacement));
  ' "$repo_root/.chezmoiignore" "$variant" "$container"
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
  local repo_root=$1 scratch=$2 chezmoi_bin=$3 os=$4 container=$5 template=$6 output=$7 variant
  variant="$scratch/reconciler-$os-$container-$(basename "$template")"
  node -e '
    const fs = require("node:fs");
    const [sourcePath, outputPath, container] = process.argv.slice(1);
    const source = fs.readFileSync(sourcePath, "utf8");
    const needle = `includeTemplate "facts.tmpl" . | fromYaml`;
    const replacement = `dict "container" ${container}`;
    if (source.split(needle).length !== 2) throw new Error("reconciler facts provider anchor changed");
    fs.writeFileSync(outputPath, source.replace(needle, replacement));
  ' "$repo_root/$template" "$variant" "$container"
  render "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$variant" "$output"
}
