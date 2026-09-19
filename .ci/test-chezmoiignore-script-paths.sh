#!/usr/bin/env bash
# test-chezmoiignore-script-paths.sh — audit normalized script paths in .chezmoiignore.
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
source_root=$(resolve_source_root "$repo_root")
scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/test-chezmoiignore.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

mkdir -p "$scratch/home" "$scratch/target" "$scratch/op-stub" "$scratch/bin"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/op-stub/op"
chmod +x "$scratch/op-stub/op"
PATH="$scratch/op-stub:$PATH"
: > "$scratch/empty.toml"

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
source_scripts=("$source_root"/.chezmoiscripts/**/run_*)
shopt -u globstar nullglob

[[ ${#source_scripts[@]} -gt 0 ]] || fail 'no .chezmoiscripts source files found'

normalized_scripts=()
for script in "${source_scripts[@]}"; do
  rel=${script#"$source_root/"}
  norm=$(normalize_script_path "$rel")
  normalized_scripts+=("$norm")
done

strip_ignore_template() {
  local src=$1 dest=$2
  node -e '
    const fs = require("node:fs");
    const [srcPath, destPath] = process.argv.slice(1);
    const content = fs.readFileSync(srcPath, "utf8");
    const beginMarker = "# BEGIN inapplicable-script-exclusions";
    const endMarker = "# END inapplicable-script-exclusions";
    const bCount = content.split(beginMarker).length - 1;
    const eCount = content.split(endMarker).length - 1;
    if (bCount === 0 && eCount === 0) {
      fs.writeFileSync(destPath, content);
      process.exit(0);
    }
    if (bCount !== 1 || eCount !== 1) {
      console.error(`strip_ignore_template: markers count mismatch (BEGIN: ${bCount}, END: ${eCount})`);
      process.exit(1);
    }
    const lines = content.split("\n");
    let inBlock = false;
    const stripped = [];
    for (const line of lines) {
      if (line.trim() === beginMarker) { inBlock = true; continue; }
      if (line.trim() === endMarker) { inBlock = false; continue; }
      if (!inBlock) stripped.push(line);
    }
    fs.writeFileSync(destPath, stripped.join("\n"));
  ' "$src" "$dest"
}

render_ignore_profile() {
  local template_src=$1 profile_json=$2 distro=$3 output=$4
  local stubbed_tmpl
  stubbed_tmpl="$scratch/tmpl-$$-$distro-$(basename "$output").tmpl"

  node -e '
    const fs = require("node:fs");
    const [srcPath, outPath, profileJson] = process.argv.slice(1);
    const src = fs.readFileSync(srcPath, "utf8");
    const needle = `{{- $f := includeTemplate "facts.tmpl" . | fromYaml }}`;
    if (src.split(needle).length !== 2) throw new Error("facts provider anchor changed");
    const profile = JSON.parse(profileJson);
    const referenced = new Set(
      [...src.matchAll(/\$f\.([A-Za-z][A-Za-z0-9]*)/g)].map((m) => m[1]),
    );
    const entries = [...referenced].sort().flatMap((key) => {
      const val = key in profile ? profile[key] : false;
      return [`"${key}"`, typeof val === "string" ? `"${val}"` : String(val)];
    });
    fs.writeFileSync(outPath, src.replace(needle, `{{- $f := dict ${entries.join(" ")} }}`));
  ' "$template_src" "$stubbed_tmpl" "$profile_json"

  local features_json
  features_json=$(node -e '
    const fs = require("node:fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    const flags = [...src.matchAll(/\(default dict \$features\)\.([A-Za-z][A-Za-z0-9]*)/g)].map(m => m[1]);
    const obj = {};
    for (const f of flags) obj[f] = true;
    console.log(JSON.stringify(obj));
  ' "$template_src")

  local override_data
  override_data=$(node -e '
    const [distro, featuresJson] = process.argv.slice(1);
    const features = JSON.parse(featuresJson);
    console.log(JSON.stringify({
      chezmoi: { os: "linux", osRelease: { id: distro } },
      features: features
    }));
  ' "$distro" "$features_json")

  env HOME="$scratch/home" PATH="$scratch/op-stub:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" \
      --destination "$scratch/target" --override-data "$override_data" \
      execute-template <"$stubbed_tmpl" >"$output"
}

render_ignore_variant() {
  if [[ $# -eq 5 ]]; then
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
    ' "$source_root/.chezmoiignore" "$template" "$os" "$desktop" "$container" "$jetson"

    env HOME="$scratch/home" PATH="$scratch/op-stub:/usr/bin:/bin" \
      "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" \
        --destination "$scratch/target" --override-data "{\"chezmoi\":{\"os\":\"$os\"}}" \
        execute-template <"$template" >"$output"
  else
    render_ignore_profile "$@"
  fi
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
is_path_ignored "$container_out" ".chezmoiscripts/90-src/reconcile-garden.sh" || fail 'container should ignore garden'
is_path_ignored "$container_out" ".chezmoiscripts/20-base/fedora/base.sh" || fail 'container should ignore 20-base'
is_path_ignored "$container_out" ".chezmoiscripts/30-components/10-nvidia.sh" || fail 'container should ignore 30-components'
macos_out="$scratch/rendered-macos"
is_path_ignored "$macos_out" ".chezmoiscripts/20-base/fedora/base.sh" || fail 'macos should ignore 20-base'
is_path_ignored "$macos_out" ".chezmoiscripts/30-components/10-nvidia.sh" || fail 'macos should ignore 30-components'

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

# ---------------------------------------------------------------------------
# 4. Guard and Fact-Skip Parity Enforcement (KTD4, KTD5)
# ---------------------------------------------------------------------------

declare -A consumer_map

discover_consumer() {
  local pattern=$1 key=$2 is_site=${3:-0}
  local files
  if [[ $is_site -eq 1 ]]; then
    files=$(grep -rn "\"site\" \"$pattern\"" "$source_root/.chezmoiscripts" | cut -d: -f1 | sort -u)
  else
    files=$(grep -rn "includeTemplate \"$pattern.sh.tmpl\"" "$source_root/.chezmoiscripts" | cut -d: -f1 | sort -u)
  fi
  local list=""
  for f in $files; do
    rel=${f#"$source_root/"}
    norm=$(normalize_script_path "$rel")
    list+="$norm "
  done
  consumer_map["$key"]="${list% }"
}

discover_consumer "gnome-guard" "gnome-guard"
discover_consumer "kde-guard" "kde-guard"
discover_consumer "shared-host-guard" "shared-host-guard"
discover_consumer "thermald-virt-host" "thermald-virt-host" 1
discover_consumer "thermald-no-battery" "thermald-no-battery" 1
discover_consumer "thermald-dytc-platform" "thermald-dytc-platform" 1
discover_consumer "no-fingerprint-reader" "no-fingerprint-reader" 1
discover_consumer "no-ir-camera" "no-ir-camera" 1
discover_consumer "jetson-off-tailnet" "jetson-off-tailnet" 1

profiles=(
  'baseline:{"desktop":"kde","battery":true,"fingerprintReader":true,"irCamera":true,"nvidia":true,"virt":false,"thinkpad":false,"sharedHost":false,"jetson":false,"container":false,"headless":false}'
  'gnome:{"desktop":"gnome","battery":true,"fingerprintReader":true,"irCamera":true,"nvidia":true,"virt":false,"thinkpad":false,"sharedHost":false,"jetson":false,"container":false,"headless":false}'
  'sharedHost:{"desktop":"kde","battery":true,"fingerprintReader":true,"irCamera":true,"nvidia":true,"virt":false,"thinkpad":false,"sharedHost":true,"jetson":false,"container":false,"headless":false}'
  'virt:{"desktop":"kde","battery":true,"fingerprintReader":true,"irCamera":true,"nvidia":true,"virt":true,"thinkpad":false,"sharedHost":false,"jetson":false,"container":false,"headless":false}'
  'battery:{"desktop":"kde","battery":false,"fingerprintReader":true,"irCamera":true,"nvidia":true,"virt":false,"thinkpad":false,"sharedHost":false,"jetson":false,"container":false,"headless":false}'
  'thinkpad:{"desktop":"kde","battery":true,"fingerprintReader":true,"irCamera":true,"nvidia":true,"virt":false,"thinkpad":true,"sharedHost":false,"jetson":false,"container":false,"headless":false}'
  'fingerprintReader:{"desktop":"kde","battery":true,"fingerprintReader":false,"irCamera":true,"nvidia":true,"virt":false,"thinkpad":false,"sharedHost":false,"jetson":false,"container":false,"headless":false}'
  'irCamera:{"desktop":"kde","battery":true,"fingerprintReader":true,"irCamera":false,"nvidia":true,"virt":false,"thinkpad":false,"sharedHost":false,"jetson":false,"container":false,"headless":false}'
  'jetson:{"desktop":"kde","battery":true,"fingerprintReader":true,"irCamera":true,"nvidia":true,"virt":false,"thinkpad":false,"sharedHost":false,"jetson":true,"container":false,"headless":false}'
)

check_parity() {
  local template_src=$1
  local -n cmap=$2
  local -n slist=$3
  local profile_filter=${4:-""}

  local stripped_tmpl
  stripped_tmpl="$scratch/stripped-$$-$(basename "$template_src").tmpl"
  strip_ignore_template "$template_src" "$stripped_tmpl"

  for p_entry in "${profiles[@]}"; do
    local p_name=${p_entry%%:*}
    local p_json=${p_entry#*:}
    if [[ -n "$profile_filter" && "$profile_filter" != "$p_name" ]]; then
      continue
    fi

    for distro in fedora ubuntu; do
      local as_is_render="$scratch/asis-$$-$p_name-$distro"
      local stripped_render="$scratch/strip-$$-$p_name-$distro"

      render_ignore_profile "$template_src" "$p_json" "$distro" "$as_is_render"
      render_ignore_profile "$stripped_tmpl" "$p_json" "$distro" "$stripped_render"

      local newly_ignored=()
      for s in "${slist[@]}"; do
        if is_path_ignored "$as_is_render" "$s" && ! is_path_ignored "$stripped_render" "$s"; then
          newly_ignored+=("$s")
        fi
      done

      local expected_firing=()
      local add_cons
      add_cons=$(node -e '
        const p = JSON.parse(process.argv[1]);
        const keys = [];
        if (p.desktop !== "gnome") keys.push("gnome-guard");
        if (p.desktop !== "kde") keys.push("kde-guard");
        if (p.sharedHost === true) keys.push("shared-host-guard");
        if (p.virt === true) keys.push("thermald-virt-host");
        if (p.battery === false) keys.push("thermald-no-battery");
        if (p.thinkpad === true) keys.push("thermald-dytc-platform");
        if (p.fingerprintReader === false) keys.push("no-fingerprint-reader");
        if (p.irCamera === false) keys.push("no-ir-camera");
        if (p.jetson === true) keys.push("jetson-off-tailnet");
        console.log(keys.join(" "));
      ' "$p_json")

      for k in $add_cons; do
        for c in ${cmap[$k]:-}; do
          expected_firing+=("$c")
        done
      done

      local -a sorted_expected_firing=()
      if [[ ${#expected_firing[@]} -gt 0 ]]; then
        mapfile -t sorted_expected_firing < <(printf '%s\n' "${expected_firing[@]}" | sort -u)
      fi

      local expected=()
      for c in "${sorted_expected_firing[@]}"; do
        [[ -z "$c" ]] && continue
        # absorption: Fedora base installer in ubuntu pass (and vice-versa) is already ignored by stripped render
        if ! is_path_ignored "$stripped_render" "$c"; then
          expected+=("$c")
        fi
      done

      local -a sorted_newly=()
      if [[ ${#newly_ignored[@]} -gt 0 ]]; then
        mapfile -t sorted_newly < <(printf '%s\n' "${newly_ignored[@]}" | sort -u)
      fi

      local -a sorted_exp=()
      if [[ ${#expected[@]} -gt 0 ]]; then
        mapfile -t sorted_exp < <(printf '%s\n' "${expected[@]}" | sort -u)
      fi

      local missing=()
      for e in "${sorted_exp[@]}"; do
        [[ -z "$e" ]] && continue
        local found=0
        for n in "${sorted_newly[@]}"; do
          if [[ "$n" == "$e" ]]; then found=1; break; fi
        done
        if [[ $found -eq 0 ]]; then
          missing+=("$e")
        fi
      done

      local extra=()
      for n in "${sorted_newly[@]}"; do
        [[ -z "$n" ]] && continue
        local found=0
        for e in "${sorted_exp[@]}"; do
          if [[ "$n" == "$e" ]]; then found=1; break; fi
        done
        if [[ $found -eq 0 ]]; then
          extra+=("$n")
        fi
      done

      if [[ ${#missing[@]} -gt 0 || ${#extra[@]} -gt 0 ]]; then
        local err_msg="profile $p_name ($distro) parity mismatch:"
        for m in "${missing[@]}"; do
          err_msg+=$'\n'"  consumer deployed without exclusion: $m"
        done
        for x in "${extra[@]}"; do
          err_msg+=$'\n'"  exclusion over-reaches: $x"
        done
        fail "$err_msg"
      fi
    done

    if [[ -z "$profile_filter" ]]; then
      pass "parity verified for profile $p_name across distro passes"
    fi
  done
}

# Run parity check on real repository
check_parity "$source_root/.chezmoiignore" consumer_map normalized_scripts

# ---------------------------------------------------------------------------
# 5. Parity Check Mutant Assertions
# ---------------------------------------------------------------------------

# AE5: inject fake gnome-guard consumer with no rule -> fails under baseline profile
declare -A mutant_map_ae5
for k in "${!consumer_map[@]}"; do mutant_map_ae5["$k"]="${consumer_map[$k]}"; done
mutant_map_ae5["gnome-guard"]+=" .chezmoiscripts/30-linux/fake-gnome-consumer.sh"
# shellcheck disable=SC2034
mutant_scripts_ae5=("${normalized_scripts[@]}" ".chezmoiscripts/30-linux/fake-gnome-consumer.sh")
if mutant_out=$(check_parity "$source_root/.chezmoiignore" mutant_map_ae5 mutant_scripts_ae5 "baseline" 2>&1); then
  fail 'AE5: fake gnome consumer should fail parity check'
fi
[[ "$mutant_out" == *".chezmoiscripts/30-linux/fake-gnome-consumer.sh"* ]] || fail "AE5 did not name target: $mutant_out"
pass 'AE5: fake gnome consumer fails under baseline profile'

# Fake shared-host-guard consumer with no rule -> fails under sharedHost profile
declare -A mutant_map_shared
for k in "${!consumer_map[@]}"; do mutant_map_shared["$k"]="${consumer_map[$k]}"; done
mutant_map_shared["shared-host-guard"]+=" .chezmoiscripts/30-linux/fake-shared-consumer.sh"
# shellcheck disable=SC2034
mutant_scripts_shared=("${normalized_scripts[@]}" ".chezmoiscripts/30-linux/fake-shared-consumer.sh")
if mutant_out=$(check_parity "$source_root/.chezmoiignore" mutant_map_shared mutant_scripts_shared "sharedHost" 2>&1); then
  fail 'fake shared-host consumer should fail parity check'
fi
[[ "$mutant_out" == *".chezmoiscripts/30-linux/fake-shared-consumer.sh"* ]] || fail "fake shared did not name target: $mutant_out"
pass 'mutant: fake shared-host consumer fails under sharedHost profile'

# Remove thermald's rule line from template copy -> fails under thinkpad profile
mutant_tmpl_thermald="$scratch/mutant-no-thermald.tmpl"
sed '/if or \$f\.virt/,/end/ { /\.chezmoiscripts\/30-linux\/install-system-19-thermald\.sh/d; }' "$source_root/.chezmoiignore" > "$mutant_tmpl_thermald"
if mutant_out=$(check_parity "$mutant_tmpl_thermald" consumer_map normalized_scripts "thinkpad" 2>&1); then
  fail 'template missing thermald rule should fail parity check'
fi
[[ "$mutant_out" == *".chezmoiscripts/30-linux/install-system-19-thermald.sh"* ]] || fail "mutant no thermald did not name target: $mutant_out"
pass 'mutant: removed thermald rule fails under thinkpad profile'

# Remove 10-nvidia.sh from sharedHost block -> fails under sharedHost profile
mutant_tmpl_nvidia="$scratch/mutant-no-nvidia-shared.tmpl"
sed '/if \$f\.sharedHost/,/end/ { /\.chezmoiscripts\/30-components\/10-nvidia\.sh/d; }' "$source_root/.chezmoiignore" > "$mutant_tmpl_nvidia"
if mutant_out=$(check_parity "$mutant_tmpl_nvidia" consumer_map normalized_scripts "sharedHost" 2>&1); then
  fail 'template missing 10-nvidia in sharedHost should fail parity check'
fi
[[ "$mutant_out" == *".chezmoiscripts/30-components/10-nvidia.sh"* ]] || fail "mutant no nvidia did not name target: $mutant_out"
pass 'mutant: removed 10-nvidia from sharedHost fails under sharedHost profile'

# Remove fedora/base.sh from sharedHost block -> fails under sharedHost profile (fedora pass)
mutant_tmpl_fedora="$scratch/mutant-no-fedora-base.tmpl"
sed '/if \$f\.sharedHost/,/end/ { /\.chezmoiscripts\/20-base\/fedora\/base\.sh/d; }' "$source_root/.chezmoiignore" > "$mutant_tmpl_fedora"
if mutant_out=$(check_parity "$mutant_tmpl_fedora" consumer_map normalized_scripts "sharedHost" 2>&1); then
  fail 'template missing fedora/base.sh in sharedHost should fail parity check'
fi
[[ "$mutant_out" == *".chezmoiscripts/20-base/fedora/base.sh"* ]] || fail "mutant no fedora base did not name target: $mutant_out"
[[ "$mutant_out" == *"fedora"* ]] || fail "mutant no fedora base should fail on fedora pass: $mutant_out"
pass 'mutant: removed fedora/base from sharedHost fails under sharedHost profile in fedora pass'

# Remove virt disjunct from thermald rule -> fails under virt profile
mutant_tmpl_virt="$scratch/mutant-no-virt.tmpl"
sed 's/if or \$f\.virt (not \$f\.battery) \$f\.thinkpad/if or (not $f.battery) $f.thinkpad/' "$source_root/.chezmoiignore" > "$mutant_tmpl_virt"
if mutant_out=$(check_parity "$mutant_tmpl_virt" consumer_map normalized_scripts "virt" 2>&1); then
  fail 'template missing virt disjunct should fail parity check'
fi
[[ "$mutant_out" == *".chezmoiscripts/30-linux/install-system-19-thermald.sh"* ]] || fail "mutant no virt did not name target: $mutant_out"
pass 'mutant: removed virt disjunct fails under virt profile'

# Remove battery disjunct from thermald rule -> fails under battery profile
mutant_tmpl_battery="$scratch/mutant-no-battery.tmpl"
sed 's/if or \$f\.virt (not \$f\.battery) \$f\.thinkpad/if or $f.virt $f.thinkpad/' "$source_root/.chezmoiignore" > "$mutant_tmpl_battery"
if mutant_out=$(check_parity "$mutant_tmpl_battery" consumer_map normalized_scripts "battery" 2>&1); then
  fail 'template missing battery disjunct should fail parity check'
fi
[[ "$mutant_out" == *".chezmoiscripts/30-linux/install-system-19-thermald.sh"* ]] || fail "mutant no battery did not name target: $mutant_out"
pass 'mutant: removed battery disjunct fails under battery profile'

# Over-reach: add chsh-zsh.sh to sharedHost block -> fails under sharedHost profile
mutant_tmpl_overreach="$scratch/mutant-overreach.tmpl"
sed '/if \$f\.sharedHost/a .chezmoiscripts/30-linux/chsh-zsh.sh' "$source_root/.chezmoiignore" > "$mutant_tmpl_overreach"
if mutant_out=$(check_parity "$mutant_tmpl_overreach" consumer_map normalized_scripts "sharedHost" 2>&1); then
  fail 'over-reaching template should fail parity check'
fi
[[ "$mutant_out" == *"exclusion over-reaches: .chezmoiscripts/30-linux/chsh-zsh.sh"* ]] || fail "mutant overreach did not name target: $mutant_out"
pass 'mutant: over-reaching rule in sharedHost fails under sharedHost profile'

printf 'test-chezmoiignore-script-paths: all tests passed\n'
