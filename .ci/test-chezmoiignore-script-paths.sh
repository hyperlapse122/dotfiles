#!/usr/bin/env bash
# test-chezmoiignore-script-paths.sh — audit normalized script paths in .chezmoiignore.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/test-chezmoiignore.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

mkdir -p "$scratch/home" "$scratch/target" "$scratch/op-stub" "$scratch/bin"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/op-stub/op"
chmod +x "$scratch/op-stub/op"
PATH="$scratch/op-stub:$PATH"

chezmoi_bin=$(type -P chezmoi)

fail() { printf 'test-chezmoiignore: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'test-chezmoiignore: ok - %s\n' "$*"; }

normalize_script_path() {
  local path=$1
  path=${path#./}
  local dir base
  dir=$(dirname "$path")
  base=$(basename "$path" .tmpl)
  base=$(sed -E 's/^run_(once_|onchange_)?(before_|after_)?//' <<< "$base")
  printf '%s/%s\n' "$dir" "$base"
}

# Collect all normalized script paths
shopt -s globstar nullglob
source_scripts=("$repo_root"/.chezmoiscripts/**/run_*)
shopt -u globstar nullglob

[[ ${#source_scripts[@]} -gt 0 ]] || fail 'no .chezmoiscripts source files found'

normalized_scripts=()
for script in "${source_scripts[@]}"; do
  rel=${script#"$repo_root/"}
  norm=$(normalize_script_path "$rel")
  normalized_scripts+=("$norm")
done

render_ignore_variant() {
  local os=$1 desktop=$2 container=$3 jetson=$4 output=$5
  local template="$scratch/ignore-$os-$desktop-$container-$jetson.tmpl"
  node -e '
    const fs = require("node:fs");
    const [srcPath, outPath, os, desktop, container, jetson] = process.argv.slice(1);
    const src = fs.readFileSync(srcPath, "utf8");
    const needle = `{{- $f := includeTemplate "facts.tmpl" . | fromYaml }}`;
    if (src.split(needle).length !== 2) throw new Error("facts provider anchor changed");
    const pinned = {
      container: container === "true",
      jetson: jetson === "true",
      desktop: desktop,
      headless: desktop === "none" ? 1 : 0
    };
    const referenced = new Set(
      [...src.matchAll(/\$f\.([A-Za-z][A-Za-z0-9]*)/g)].map((m) => m[1]),
    );
    const entries = [...referenced].sort().flatMap((key) => {
      const val = key in pinned ? pinned[key] : false;
      return [`"${key}"`, typeof val === "string" ? `"${val}"` : String(val)];
    });
    fs.writeFileSync(outPath, src.replace(needle, `{{- $f := dict ${entries.join(" ")} }}`));
  ' "$repo_root/.chezmoiignore" "$template" "$os" "$desktop" "$container" "$jetson"

  env HOME="$scratch/home" PATH="$scratch/op-stub:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" \
      --destination "$scratch/target" --override-data "{\"chezmoi\":{\"os\":\"$os\"}}" \
      execute-template <"$template" >"$output"
}

is_path_ignored() {
  local rendered=$1 path=$2 pattern
  path=${path#./}
  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    pattern=${pattern#./}
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    # shellcheck disable=SC2053
    if [[ "$path" == $pattern || "$path" == "$pattern"/* ]]; then
      return 0
    fi
  done <"$rendered"
  return 1
}

validate_rendered_rules() {
  local rendered=$1 variant_name=$2
  local line pattern matched

  while IFS= read -r line || [[ -n "$line" ]]; do
    pattern=${line#./}
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue


    if [[ "$pattern" =~ run_(once_|onchange_)?(before_|after_)? ]] || [[ "$pattern" == *.tmpl* ]]; then
      fail "variant $variant_name has source metadata token in live ignore rule: $pattern"
    fi

    # If the rule targets .chezmoiscripts, it must match at least one normalized script
    if [[ "$pattern" == .chezmoiscripts/* ]]; then
      matched=0
      for norm in "${normalized_scripts[@]}"; do
        # shellcheck disable=SC2053
        if [[ "$norm" == $pattern || "$norm" == "$pattern"/* ]]; then
          matched=1
          break
        fi
      done
      if [[ $matched -eq 0 ]]; then
        fail "variant $variant_name ignore rule matches zero normalized scripts: $pattern"
      fi
    fi
  done <"$rendered"
}

# 1. Test clean variants
variants=(
  "linux:gnome:false:false:linux-gnome"
  "linux:kde:false:false:linux-kde"
  "linux:none:false:false:linux-headless"
  "linux:none:false:true:linux-jetson"
  "linux:none:true:false:linux-container"
  "darwin:none:false:false:macos"
)

for v in "${variants[@]}"; do
  IFS=':' read -r os desk cont jet label <<< "$v"
  out_file="$scratch/rendered-$label"
  render_ignore_variant "$os" "$desk" "$cont" "$jet" "$out_file"
  validate_rendered_rules "$out_file" "$label"
done


# 2. Assert specific expected gating behavior per variant
# Container variant ignores all host provisioning scripts
container_out="$scratch/rendered-linux-container"
is_path_ignored "$container_out" ".chezmoiscripts/30-linux/chsh-zsh.sh" || fail 'container should ignore 30-linux'
is_path_ignored "$container_out" ".chezmoiscripts/50-linux-kde/config-kde-settings.sh" || fail 'container should ignore 50-linux-kde'
is_path_ignored "$container_out" ".chezmoiscripts/60-build/build-mxm4-haptic.sh" || fail 'container should ignore mxm4-haptic'
is_path_ignored "$container_out" ".chezmoiscripts/90-src/reconcile-garden.sh" || fail 'container should ignore garden'
is_path_ignored "$container_out" ".chezmoiscripts/20-base/fedora/base.sh" || fail 'container should ignore 20-base'
is_path_ignored "$container_out" ".chezmoiscripts/30-components/fedora/10-nvidia.sh" || fail 'container should ignore 30-components'
gnome_out="$scratch/rendered-linux-gnome"
macos_out="$scratch/rendered-macos"
is_path_ignored "$macos_out" ".chezmoiscripts/20-base/fedora/base.sh" || fail 'macos should ignore 20-base'
is_path_ignored "$macos_out" ".chezmoiscripts/30-components/fedora/10-nvidia.sh" || fail 'macos should ignore 30-components'

# Jetson ignores mxm4-haptic, Fedora desktop has it eligible
jetson_out="$scratch/rendered-linux-jetson"
is_path_ignored "$jetson_out" ".chezmoiscripts/60-build/build-mxm4-haptic.sh" || fail 'jetson should ignore mxm4-haptic'
! is_path_ignored "$gnome_out" ".chezmoiscripts/60-build/build-mxm4-haptic.sh" || fail 'fedora gnome should not ignore mxm4-haptic'
pass 'expected script gating behavior verified across variants'

# 3. Mutant assertions
# Mutant A: source-style token in ignore rule fails
mutant_a="$scratch/mutant-a"
printf '.chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-settings.sh.tmpl\n' > "$mutant_a"
if (validate_rendered_rules "$mutant_a" "mutant-a") >/dev/null 2>&1; then
  fail 'mutant with source-style run_onchange_ token should fail'
fi
pass 'mutant with source-style prefix fails'

# Mutant B: .tmpl suffix fails
mutant_b="$scratch/mutant-b"
printf '.chezmoiscripts/50-linux-kde/*.sh.tmpl\n' > "$mutant_b"
if (validate_rendered_rules "$mutant_b" "mutant-b") >/dev/null 2>&1; then
  fail 'mutant with .tmpl suffix should fail'
fi
pass 'mutant with .tmpl suffix fails'

# Mutant C: no-match script directory fails
mutant_c="$scratch/mutant-c"
printf '.chezmoiscripts/99-nonexistent/*.sh\n' > "$mutant_c"
if (validate_rendered_rules "$mutant_c" "mutant-c") >/dev/null 2>&1; then
  fail 'mutant with non-matching script rule should fail'
fi
pass 'mutant with no-match rule fails'

printf 'test-chezmoiignore-script-paths: all tests passed\n'
