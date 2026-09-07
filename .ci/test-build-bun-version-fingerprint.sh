#!/usr/bin/env bash
set -euo pipefail

# test-build-bun-version-fingerprint.sh -- the two bun-compiling build scripts
# must rebuild when the release lock moves bun, and must NOT rebuild when it
# moves anything else.
#
# Both `.chezmoiscripts/00-tools/run_onchange_after_10-build-command-reconcile.sh.tmpl`
# and `.chezmoiscripts/60-build/run_onchange_after_build-settings-reconcile.sh.tmpl`
# compile a binary that embeds a bun runtime. No tracked file changes when the
# lock bumps bun, so each passes the locked bun version to fingerprint.tmpl as a
# `values` entry named `bun-version`, and exports the same version as
# DOTFILES_BUN_VERSION so the vite build task's `env` declaration carries it into
# the vp cache key.
#
# The design is deliberately narrow: a `values` entry rather than a glob over
# .chezmoidata/releases.json, so an unrelated tool's bump does not recompile
# both binaries. Nothing else asserted that. `test-build-command-reconcile.sh`
# only rewrites SRC in the rendered script and never reads the fingerprint
# block, so a dropped `values` entry -- or a widened glob -- regressed silently.
#
# FOUR ASSERTIONS, against renders of a scratch copy of the source tree:
#   1. Each script emits exactly one `#   value:bun-version <digest>` line, and
#      the digest is sha256 of the lock's bun version, derived here from
#      .chezmoidata/releases.json rather than read back out of the render.
#   2. Each script exports DOTFILES_BUN_VERSION set to that same version.
#   3. Bumping only releases.tools.bun.version changes BOTH fingerprint blocks,
#      and the new value:bun-version digest matches the bumped version.
#   4. Bumping an unrelated tool's version leaves BOTH fingerprint blocks byte
#      identical. This is the assertion that proves the entry is narrow.
#
# Every render runs against a symlink farm with a real, writable .chezmoidata,
# so the repository's own lock is never edited.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.ci/lib/render-scratch.sh
source "$repo_root/.ci/lib/render-scratch.sh"
setup_render_scratch build-bun-version-fingerprint

fail() { printf 'build bun-version fingerprint: %s\n' "$*" >&2; exit 1; }
pass() { printf 'build bun-version fingerprint: ok - %s\n' "$*"; }

unrelated_tool=shellcheck
bumped_bun_version=bun-v0.0.0-fingerprint-gate
bumped_unrelated_version=v0.0.0-fingerprint-gate

scripts=(
  .chezmoiscripts/00-tools/run_onchange_after_10-build-command-reconcile.sh.tmpl
  .chezmoiscripts/60-build/run_onchange_after_build-settings-reconcile.sh.tmpl
)
for script in "${scripts[@]}"; do
  [[ -f "$repo_root/$script" ]] || fail "$script is missing"
done

command -v jq >/dev/null 2>&1 || fail 'jq is required'
command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is required'
lock_python=''
for candidate in /usr/bin/python3 python3; do
  command -v "$candidate" >/dev/null 2>&1 || continue
  lock_python=$candidate
  break
done
[[ -n $lock_python ]] || fail 'python3 is required to rewrite the lock fixture'

# A symlink farm over the whole source tree, with .chezmoidata copied in as real
# files so the lock can be rewritten per fixture. The fingerprint globs reach
# mise.toml and packages/**, which stay shared through their symlinks, so every
# fixture's file digests are identical by construction and only the lock differs.
make_source_fixture() {
  local name=$1
  local dest="$scratch/source-$name"
  local entry
  rm -rf -- "$dest"
  mkdir -p -- "$dest"
  for entry in "$repo_root"/* "$repo_root"/.[!.]*; do
    [[ -e "$entry" ]] || continue
    ln -s -- "$entry" "$dest/$(basename -- "$entry")"
  done
  rm -f -- "$dest/.chezmoidata"
  # -L, and the regular-file guard below: when $repo_root is itself a symlink
  # farm (the gate's own tamper harness renders one), a plain `cp -a` would copy
  # the .chezmoidata SYMLINK, and set_lock_version would then rewrite the real
  # repository's lock through it.
  mkdir -p -- "$dest/.chezmoidata"
  cp -a -L -- "$repo_root/.chezmoidata/." "$dest/.chezmoidata/"
  [[ -f "$dest/.chezmoidata/releases.json" && ! -L "$dest/.chezmoidata/releases.json" ]] ||
    fail "fixture $name did not get a private copy of .chezmoidata/releases.json"
  printf '%s\n' "$dest"
}

set_lock_version() {
  local dir=$1 tool=$2 version=$3
  [[ $dir == "$scratch"/* ]] || fail "refusing to rewrite a lock outside the scratch tree: $dir"
  "$lock_python" -c '
import json, sys
path, tool, version = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
tools = data["releases"]["tools"]
if tool not in tools:
    sys.exit(f"no lock entry for tool {tool!r}")
tools[tool]["version"] = version
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
' "$dir/.chezmoidata/releases.json" "$tool" "$version"
}

lock_version() {
  local dir=$1 tool=$2 version
  version=$(jq -r --arg tool "$tool" '.releases.tools[$tool].version' "$dir/.chezmoidata/releases.json")
  [[ -n $version && $version != null ]] || fail "the lock in $dir carries no version for $tool"
  printf '%s\n' "$version"
}

digest_of() {
  printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# The template's own `{{ if }}` guard renders nothing off linux/darwin, so the
# os/arch override makes the gate runnable anywhere.
render_script() {
  local source_dir=$1 script=$2 out=$3 err=$4
  env PATH="$scratch/bin:$PATH" chezmoi \
    --config "$scratch/empty.toml" \
    --source "$source_dir" \
    --destination "$scratch/target" \
    --override-data '{"chezmoi":{"os":"linux","arch":"amd64"}}' \
    execute-template <"$source_dir/$script" >"$out" 2>"$err" ||
    {
      printf 'build bun-version fingerprint: rendering %s failed\n' "$script" >&2
      sed 's/^/  /' "$err" >&2
      exit 1
    }
}

# The fingerprint block is the run of `#   <name>  <sha256>` comment lines
# fingerprint.tmpl emits; nothing else in these scripts has that shape.
fingerprint_block() {
  grep -E '^#   [^ ]+  [0-9a-f]{64}$' -- "$1" || true
}

# label -> "<fixture dir>", rendered once per script and cached on disk.
render_all() {
  local label=$1 source_dir=$2 script index=0
  for script in "${scripts[@]}"; do
    render_script "$source_dir" "$script" \
      "$scratch/$label.$index.out" "$scratch/$label.$index.err"
    fingerprint_block "$scratch/$label.$index.out" >"$scratch/$label.$index.fingerprint"
    index=$((index + 1))
  done
}

baseline_dir=$(make_source_fixture baseline)
render_all baseline "$baseline_dir"

bun_version=$(lock_version "$baseline_dir" bun)
expected_digest=$(digest_of "$bun_version")

index=0
for script in "${scripts[@]}"; do
  out="$scratch/baseline.$index.out"
  mapfile -t value_lines < <(grep -E '^#   value:bun-version  [0-9a-f]{64}$' -- "$out" || true)
  ((${#value_lines[@]} == 1)) ||
    fail "$script emits ${#value_lines[@]} 'value:bun-version' fingerprint lines, expected exactly 1 (a lost \"values\" entry stops a bun bump from rebuilding)"
  rendered_digest=${value_lines[0]##* }
  [[ $rendered_digest == "$expected_digest" ]] ||
    fail "$script fingerprints bun-version as $rendered_digest, but sha256 of the locked bun version ($bun_version) is $expected_digest"

  grep -qxF "export DOTFILES_BUN_VERSION=\"$bun_version\"" -- "$out" ||
    fail "$script does not export DOTFILES_BUN_VERSION=\"$bun_version\" (the vite build task declares it as a cache-key env input)"
  index=$((index + 1))
done
pass "both build scripts fingerprint and export the locked bun version $bun_version"

bun_bump_dir=$(make_source_fixture bun-bump)
set_lock_version "$bun_bump_dir" bun "$bumped_bun_version"
render_all bun-bump "$bun_bump_dir"

bumped_digest=$(digest_of "$bumped_bun_version")
index=0
for script in "${scripts[@]}"; do
  if cmp -s "$scratch/baseline.$index.fingerprint" "$scratch/bun-bump.$index.fingerprint"; then
    fail "$script keeps the same fingerprint block after a bun bump; chezmoi would not re-run the build"
  fi
  grep -qxF "#   value:bun-version  $bumped_digest" -- "$scratch/bun-bump.$index.out" ||
    fail "$script does not fingerprint the bumped bun version $bumped_bun_version"
  index=$((index + 1))
done
pass 'a bun bump moves both fingerprint blocks'

unrelated_dir=$(make_source_fixture unrelated-bump)
set_lock_version "$unrelated_dir" "$unrelated_tool" "$bumped_unrelated_version"
render_all unrelated-bump "$unrelated_dir"

index=0
for script in "${scripts[@]}"; do
  cmp -s "$scratch/baseline.$index.fingerprint" "$scratch/unrelated-bump.$index.fingerprint" || {
    printf 'build bun-version fingerprint: %s changed its fingerprint block after bumping %s, which it does not build with; the bun-version dependency must stay a narrow "values" entry, never a glob over the lock\n' \
      "$script" "$unrelated_tool" >&2
    diff -u "$scratch/baseline.$index.fingerprint" "$scratch/unrelated-bump.$index.fingerprint" >&2 || true
    exit 1
  }
  index=$((index + 1))
done
pass "an unrelated bump ($unrelated_tool) leaves both fingerprint blocks unchanged"
