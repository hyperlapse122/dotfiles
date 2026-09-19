# shellcheck shell=bash
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
# genuine per-script difference, and require_file, render_ignore, and
# render_reconciler are the callers of it.
#
# require_file, render_ignore, and render_reconciler each join a source-state
# path (a .chezmoiignore, a .chezmoiscripts/... template, and so on) onto the
# source root rather than onto repo_root, resolved through
# .ci/lib/source-root.sh's join_source_state; render() itself keeps
# `--source "$repo_root"` because chezmoi descends into the source root on
# its own. When .chezmoiroot is absent, the source root falls back to
# repo_root unchanged.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/.ci/lib/source-root.sh"

require_file() {
  local repo_root=$1 path=$4 target
  target=$(join_source_state "$repo_root" "$path") || fail "missing source surface $path"
  [[ -f "$target" ]] || fail "missing source surface $path"
}

render() {
  local repo_root=$1 scratch=$2 chezmoi_bin=$3 os=$4 input=$5 output=$6
  local override_data=${7:-}
  [[ -n "$override_data" ]] || override_data="{\"chezmoi\":{\"os\":\"$os\"}}"
  env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" \
      --destination "$scratch/target" --override-data "$override_data" \
      execute-template <"$input" >"$output"
}

# Rewrite a template so fixtures pin deterministic host facts instead of
# consulting the live host. The literal dict preserves explicit pins
# (container, jetson, desktop, distro, headless, nvidia) and sets any other
# fact referenced through a bound template variable to false. A template with no
# facts include passes through unchanged; an unrewritten include fails loudly.
write_fact_stub() {
  local source_path=$1 output_path=$2 container=$3 jetson=${4:-false} desktop=${5:-gnome}

  if ! grep -qF 'includeTemplate "facts.tmpl"' "$source_path"; then
    cat "$source_path" > "$output_path"
    return 0
  fi

  local vars
  vars=$(sed -n -E 's/.*\$([A-Za-z0-9_]+)[[:space:]]*:?=[[:space:]]*includeTemplate "facts\.tmpl" (\.|\.ctx)[[:space:]]*\|[[:space:]]*fromYaml.*/\1/p' "$source_path" | sort -u)

  # Two call forms reach facts.tmpl: a top-level template passes `.`, while a
  # shared partial must pass `.ctx` because a partial's `.` is only ever what its
  # caller handed it. Both are matched, so a fixture can pin facts for either.
  # `desktop` is a parameter rather than a constant: the fact is derived from
  # `lookPath` and KDE wins a tie, so a PATH stub cannot produce a `gnome`
  # rendering on a host that has plasmashell — only substitution can.
  local stub="dict \"container\" $container \"jetson\" $jetson \"desktop\" \"$desktop\" \"distro\" \"fedora\" \"headless\" false \"nvidia\" false"
  local fact
  while IFS= read -r fact; do
    [[ -n "$fact" ]] || continue
    case "$fact" in
      container|jetson|desktop|distro|headless|nvidia) ;;
      *) stub+=" \"$fact\" false" ;;
    esac
  done < <(
    for v in $vars; do
      { grep -o -E "\\\$${v}\\.[A-Za-z0-9_]+" "$source_path" || true; } | sed "s/^\\\$${v}\\.//"
    done | sort -u
  )

  sed -e "s|includeTemplate \"facts.tmpl\" \. \| fromYaml|$stub|g" \
      -e "s|includeTemplate \"facts.tmpl\" \.ctx \| fromYaml|$stub|g" \
      "$source_path" > "$output_path"

  if grep -qF 'includeTemplate "facts.tmpl"' "$output_path"; then
    fail "write_fact_stub: unrewritten facts include in $source_path"
  fi
}

render_ignore() {
  local repo_root=$1 scratch=$2 chezmoi_bin=$3 os=$4 container=$5 output=$6 jetson=${7:-false} desktop=${8:-gnome} variant ignore_path
  variant="$scratch/ignore-$os-$desktop-$container-$jetson.tmpl"
  ignore_path=$(join_source_state "$repo_root" .chezmoiignore) || fail "missing source surface .chezmoiignore"
  write_fact_stub "$ignore_path" "$variant" "$container" "$jetson" "$desktop"
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
  local repo_root=$1 scratch=$2 chezmoi_bin=$3 os=$4 container=$5 template=$6 output=$7 jetson=${8:-false} variant template_path
  variant="$scratch/reconciler-$os-$container-$jetson-$(basename "$template")"
  local stub="dict \"container\" $container \"jetson\" $jetson \"desktop\" \"gnome\" \"distro\" \"fedora\" \"headless\" false \"nvidia\" false"
  template_path=$(join_source_state "$repo_root" "$template") || fail "missing source surface $template"
  sed 's|includeTemplate "facts.tmpl" \. \| fromYaml|'"$stub"'|g' "$template_path" > "$variant"
  render "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$variant" "$output"
}
