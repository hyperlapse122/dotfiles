#!/usr/bin/env bash
set -euo pipefail

# Asserts .install-prerequisites.sh's bootstrap preflight arrays and
# .chezmoidata/gpg.yaml's declared steady-state package set agree per distro,
# following .ci/test-gpg-key-data.sh's extraction-and-parity style:
#   1. preflight_fedora's/preflight_ubuntu's base `pkgs=(...)` array matches
#      gpg.yaml's `packages.<fedora|debian>.core` list, set-equal.
#   2. Both functions' `case "$(hook_desktop)")` kde/gnome package literals
#      match gpg.yaml's `packages.desktopPinentry.kde`/`.gnome` scalars.
#   3. Mutant fixtures prove both checks actually fail on drift, naming both
#      values -- one with a mutated gpg.yaml core list, one with a mutated
#      preflight array (a scratch copy; the real file is never modified).
#   4. The consumer chezmoiscript (run_after_install-gpg-packages.sh.tmpl) is
#      actually rendered for Fedora and Ubuntu, and its `gpg_packages=(...)`
#      array is asserted to match gpg.yaml's core+paperBackup union. Without
#      this, checks 1-3 could stay green while the template itself referenced
#      the wrong data path and installed nothing -- gpg.yaml would agree with
#      preflight, and the consumer would still be broken.
#
# gpg.yaml's `paperBackup` lists are NOT compared to preflight: preflight has
# no reason to install the paper-backup/QR tools (they are not needed to
# bootstrap or decrypt chezmoi data), so their absence from preflight is
# expected, not drift. Check 4 still verifies paperBackup reaches the
# consumer script's install set.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$repo_root"
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
source_root=$(resolve_source_root "$repo_root")

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/gpg-packages-parity-test
mkdir -p "$scratch_root"
chmod 0700 "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

fail() {
  printf 'test-gpg-packages-parity: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'test-gpg-packages-parity: ok - %s\n' "$*"
}

# --- Extraction helpers (fixed-shape scans) -----------------------------------

extract_function_body() {
  local file="$1" func_name="$2"
  awk -v fn="$func_name" '
    $0 ~ "^"fn"\\(\\) \\{" { infn=1 }
    infn { print }
    infn && /^}/ { exit }
  ' "$file"
}

extract_preflight_pkgs() {
  local body="$1"
  sed -nE 's/^[[:space:]]*local -a pkgs=\(([^)]*)\).*/\1/p' <<<"$body" | head -1 | xargs
}

extract_preflight_case_pkg() {
  local body="$1" branch="$2"
  sed -nE "s/^[[:space:]]*${branch}\\) pkgs\\+=\\(([^)]*)\\).*/\\1/p" <<<"$body" | head -1 | xargs
}

# Prints lines indented more than the first line matching `pattern`, until a
# line at or below that indent level (blank lines are skipped, not treated as
# a dedent). Used to descend one YAML nesting level per call.
extract_yaml_block() {
  local pattern="$1"
  awk -v pat="$pattern" '
    $0 ~ pat { found=1; indent=match($0,/[^ ]/)-1; next }
    found {
      if ($0 ~ /^[[:space:]]*$/) { next }
      cur=match($0,/[^ ]/)-1
      if (cur <= indent) { exit }
      print
    }
  '
}

extract_yaml_list_items() {
  sed -nE 's/^[[:space:]]*-[[:space:]]*(.+)$/\1/p' | xargs
}

extract_gpg_core() {
  local data_file="$1" distro="$2"
  extract_yaml_block "^[[:space:]]*${distro}:[[:space:]]*\$" < "$data_file" \
    | extract_yaml_block "^[[:space:]]*core:[[:space:]]*\$" \
    | extract_yaml_list_items
}

extract_gpg_paper_backup() {
  local data_file="$1" distro="$2"
  extract_yaml_block "^[[:space:]]*${distro}:[[:space:]]*\$" < "$data_file" \
    | extract_yaml_block "^[[:space:]]*paperBackup:[[:space:]]*\$" \
    | extract_yaml_list_items
}

extract_gpg_desktop_pinentry() {
  local data_file="$1" desktop="$2"
  sed -nE "s/^[[:space:]]*${desktop}:[[:space:]]*([^[:space:]]+).*/\\1/p" "$data_file" | head -1
}

# Renders the consumer chezmoiscript for one distro fixture in an isolated
# scratch chezmoi config (empty data, restricted PATH) so it never reaches
# this host's real chezmoi config or 1Password hook.
render_gpg_consumer_script() {
  local chezmoi_bin="$1" repo_root="$2" os_id="$3" render_scratch="$4" out_file="$5"
  mkdir -p "$render_scratch/home" "$render_scratch/target"
  printf '[data]\n' > "$render_scratch/empty.toml"
  local err_file="$render_scratch/err.txt"
  if ! env HOME="$render_scratch/home" PATH="/usr/bin:/bin" \
    "$chezmoi_bin" --config "$render_scratch/empty.toml" --source "$repo_root" \
      --destination "$render_scratch/target" \
      --override-data "{\"chezmoi\":{\"os\":\"linux\",\"osRelease\":{\"id\":\"${os_id}\"}}}" \
      execute-template < "$tmpl_file" > "$out_file" 2>"$err_file"
  then
    fail "failed to render $tmpl_file for osRelease.id=$os_id: $(cat "$err_file")"
  fi
}

# Prints the quoted string literals inside `gpg_packages=( ... )` in a
# rendered script, space-joined -- the array as the consumer script will
# actually see it at install time.
extract_rendered_gpg_packages() {
  local rendered_file="$1"
  awk '
    /^gpg_packages=\(/ { infn=1; next }
    infn && /^\)/ { exit }
    infn { print }
  ' "$rendered_file" | sed -nE 's/^[[:space:]]*"([^"]+)".*/\1/p' | xargs
}

# --- Validation ----------------------------------------------------------------

check_core_parity() {
  local hook_file="$1" data_file="$2" func_name="$3" gpg_distro_key="$4" label="$5"

  local body preflight_pkgs gpg_pkgs
  body=$(extract_function_body "$hook_file" "$func_name")
  [[ -n "$body" ]] || fail "could not find function $func_name in $hook_file"

  preflight_pkgs=$(extract_preflight_pkgs "$body")
  [[ -n "$preflight_pkgs" ]] || fail "could not extract pkgs array from $func_name in $hook_file"

  gpg_pkgs=$(extract_gpg_core "$data_file" "$gpg_distro_key")
  [[ -n "$gpg_pkgs" ]] || fail "could not extract packages.${gpg_distro_key}.core from $data_file"

  local sorted_preflight sorted_gpg
  sorted_preflight=$(tr ' ' '\n' <<<"$preflight_pkgs" | sort | xargs)
  sorted_gpg=$(tr ' ' '\n' <<<"$gpg_pkgs" | sort | xargs)

  if [[ "$sorted_preflight" != "$sorted_gpg" ]]; then
    fail "$label core package set mismatch: $func_name has '$preflight_pkgs', gpg.yaml packages.${gpg_distro_key}.core has '$gpg_pkgs'"
  fi

  local branch preflight_case gpg_case
  for branch in kde gnome; do
    preflight_case=$(extract_preflight_case_pkg "$body" "$branch")
    [[ -n "$preflight_case" ]] || fail "could not extract $branch) pkgs+=(...) from $func_name in $hook_file"
    gpg_case=$(extract_gpg_desktop_pinentry "$data_file" "$branch")
    [[ -n "$gpg_case" ]] || fail "could not extract packages.desktopPinentry.$branch from $data_file"
    if [[ "$preflight_case" != "$gpg_case" ]]; then
      fail "$label $branch pinentry mismatch: $func_name has '$preflight_case', gpg.yaml packages.desktopPinentry.$branch has '$gpg_case'"
    fi
  done
}

sorted_words() {
  tr ' ' '\n' <<<"$1" | sort | xargs
}

# Renders the consumer script for one distro and asserts its gpg_packages
# array is exactly gpg.yaml's core+paperBackup union for that distro.
check_consumer_render() {
  local chezmoi_bin="$1" repo_root="$2" data_file="$3" os_id="$4" gpg_distro_key="$5" scratch_dir="$6"

  local rendered="$scratch_dir/rendered-$os_id.sh"
  render_gpg_consumer_script "$chezmoi_bin" "$repo_root" "$os_id" "$scratch_dir/render-$os_id" "$rendered"

  local rendered_pkgs core_pkgs paper_pkgs expected_pkgs
  rendered_pkgs=$(extract_rendered_gpg_packages "$rendered")
  [[ -n "$rendered_pkgs" ]] || fail "rendered $tmpl_file for osRelease.id=$os_id produced an empty gpg_packages array"

  core_pkgs=$(extract_gpg_core "$data_file" "$gpg_distro_key")
  paper_pkgs=$(extract_gpg_paper_backup "$data_file" "$gpg_distro_key")
  expected_pkgs="$core_pkgs $paper_pkgs"

  if [[ "$(sorted_words "$rendered_pkgs")" != "$(sorted_words "$expected_pkgs")" ]]; then
    fail "osRelease.id=$os_id rendered gpg_packages '$rendered_pkgs' does not match gpg.yaml packages.${gpg_distro_key}.core+paperBackup '$expected_pkgs'"
  fi
}

# --- Production checks ----------------------------------------------------------

hook_file="$repo_root/.install-prerequisites.sh"
gpg_data="$source_root/.chezmoidata/gpg.yaml"
tmpl_file="$source_root/.chezmoiscripts/80-keys/run_after_install-gpg-packages.sh.tmpl"
chezmoi_bin=$(command -v chezmoi) || fail "chezmoi is required on PATH"

check_core_parity "$hook_file" "$gpg_data" preflight_fedora fedora "fedora"
pass "preflight_fedora core packages and kde/gnome pinentry agree with gpg.yaml"

check_core_parity "$hook_file" "$gpg_data" preflight_ubuntu debian "debian/ubuntu"
pass "preflight_ubuntu core packages and kde/gnome pinentry agree with gpg.yaml"

check_consumer_render "$chezmoi_bin" "$repo_root" "$gpg_data" fedora fedora "$scratch"
pass "run_after_install-gpg-packages.sh.tmpl renders fedora's core+paperBackup set from gpg.yaml"

check_consumer_render "$chezmoi_bin" "$repo_root" "$gpg_data" ubuntu debian "$scratch"
pass "run_after_install-gpg-packages.sh.tmpl renders debian/ubuntu's core+paperBackup set from gpg.yaml"

# --- Fixture and mutant checks ----------------------------------------------------

# Fixture 1: a mutated gpg.yaml core package fails, naming both values.
mutant_data="$scratch/mutant-gpg.yaml"
sed 's/gnupg2-scdaemon/gnupg2-scdaemon-renamed/' "$gpg_data" > "$mutant_data"
mutant_err=$(check_core_parity "$hook_file" "$mutant_data" preflight_fedora fedora "fedora" 2>&1) || true
if ! grep -q "gnupg2-scdaemon-renamed" <<<"$mutant_err" || ! grep -q "gnupg2-scdaemon" <<<"$mutant_err"; then
  fail "mutant gpg.yaml core package did not fail naming both values; output was: $mutant_err"
fi
pass "fixture gpg.yaml with a renamed fedora core package fails naming both values"

# Fixture 2: a mutated preflight array (scratch copy; the real file is untouched) fails.
mutant_hook="$scratch/mutant-install-prerequisites.sh"
sed 's/local -a pkgs=(gnupg scdaemon pcscd pinentry-curses libsecret-tools)/local -a pkgs=(gnupg scdaemon-renamed pcscd pinentry-curses libsecret-tools)/' \
  "$hook_file" > "$mutant_hook"
mutant_hook_err=$(check_core_parity "$mutant_hook" "$gpg_data" preflight_ubuntu debian "debian/ubuntu" 2>&1) || true
if ! grep -q "scdaemon-renamed" <<<"$mutant_hook_err" || ! grep -q "scdaemon" <<<"$mutant_hook_err"; then
  fail "mutant preflight_ubuntu array did not fail naming both values; output was: $mutant_hook_err"
fi
pass "fixture preflight_ubuntu with a renamed package fails naming both values"

# Fixture 3: the rendered consumer script (from the real, unmutated tree) is
# compared against a mutated expected set (mutant_data's renamed fedora core
# package) and fails, proving check_consumer_render actually detects a
# rendered-vs-declared divergence rather than trivially passing.
mutant_render_err=$(check_consumer_render "$chezmoi_bin" "$repo_root" "$mutant_data" fedora fedora "$scratch" 2>&1) || true
if ! grep -q "gnupg2-scdaemon-renamed" <<<"$mutant_render_err"; then
  fail "mutant expected-set check_consumer_render did not fail naming the mismatch; output was: $mutant_render_err"
fi
pass "fixture rendered-vs-declared mismatch in check_consumer_render fails"

pass "all GPG package parity checks passed"
