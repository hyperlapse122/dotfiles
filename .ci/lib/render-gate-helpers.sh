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
# Rewrite a repo-meta template so the fixture can pin `container`, replacing the
# real fact provider with a literal dict. The dict is built from the `$f.<key>`
# references the template ACTUALLY makes, because a hand-listed subset silently
# omits every fact added later and chezmoi then fails with `map has no entry for
# key` in CI only.
write_fact_stub() {
  local source_path=$1 output_path=$2 container=$3 jetson=${4:-false}
  python3 - "$source_path" "$output_path" "$container" "$jetson" <<'PY_EOF'
import sys, re

source_path, output_path, container, jetson = sys.argv[1:5]
with open(source_path, "r", encoding="utf-8") as f:
    source = f.read()

needle = '{{- $f := includeTemplate "facts.tmpl" . | fromYaml }}'
if needle not in source:
    raise RuntimeError("facts provider anchor changed")

pinned = {
    "container": container == "true",
    "jetson": jetson == "true",
    "desktop": "gnome",
    "distro": "fedora",
}

referenced = sorted(set(m.group(1) for m in re.finditer(r'\$f\.([A-Za-z][A-Za-z0-9]*)', source)))
if not referenced:
    raise RuntimeError("no $f references found; anchor or usage changed")

entries = []
for key in referenced:
    val = pinned.get(key, False)
    if isinstance(val, bool):
        entries.append(f'"{key}" {"true" if val else "false"}')
    elif isinstance(val, str):
        entries.append(f'"{key}" "{val}"')
    else:
        entries.append(f'"{key}" {val}')

replacement = f'{{{{- $f := dict {" ".join(entries)} }}}}'
new_source = source.replace(needle, replacement, 1)
with open(output_path, "w", encoding="utf-8") as f:
    f.write(new_source)
PY_EOF
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
  python3 - "$repo_root/$template" "$variant" "$container" "$jetson" <<'PY_EOF'
import sys, re

source_path, output_path, container, jetson = sys.argv[1:5]
with open(source_path, "r", encoding="utf-8") as f:
    source = f.read()

needle = 'includeTemplate "facts.tmpl" . | fromYaml'
if needle not in source:
    raise RuntimeError("reconciler facts provider anchor changed")

pinned = {
    "container": container == "true",
    "jetson": jetson == "true",
    "desktop": "gnome",
    "distro": "fedora",
}

referenced = sorted(set(m.group(1) for m in re.finditer(r'\$facts\.([A-Za-z][A-Za-z0-9]*)', source)))
entries = []
for key in referenced:
    val = pinned.get(key, False)
    if isinstance(val, bool):
        entries.append(f'"{key}" {"true" if val else "false"}')
    elif isinstance(val, str):
        entries.append(f'"{key}" "{val}"')
    else:
        entries.append(f'"{key}" {val}')

replacement = f'dict {" ".join(entries)}'
new_source = source.replace(needle, replacement, 1)
with open(output_path, "w", encoding="utf-8") as f:
    f.write(new_source)
PY_EOF
  render "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$variant" "$output"
}
