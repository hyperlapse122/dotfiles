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
#
# gpg.yaml's `paperBackup` lists are NOT compared here: preflight has no
# reason to install the paper-backup/QR tools (they are not needed to
# bootstrap or decrypt chezmoi data), so their absence from preflight is
# expected, not drift.

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

extract_gpg_desktop_pinentry() {
  local data_file="$1" desktop="$2"
  sed -nE "s/^[[:space:]]*${desktop}:[[:space:]]*([^[:space:]]+).*/\\1/p" "$data_file" | head -1
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

# --- Production checks ----------------------------------------------------------

hook_file="$repo_root/.install-prerequisites.sh"
gpg_data="$source_root/.chezmoidata/gpg.yaml"

check_core_parity "$hook_file" "$gpg_data" preflight_fedora fedora "fedora"
pass "preflight_fedora core packages and kde/gnome pinentry agree with gpg.yaml"

check_core_parity "$hook_file" "$gpg_data" preflight_ubuntu debian "debian/ubuntu"
pass "preflight_ubuntu core packages and kde/gnome pinentry agree with gpg.yaml"

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

pass "all GPG package parity checks passed"
