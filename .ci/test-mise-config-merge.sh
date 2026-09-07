#!/usr/bin/env bash
# Prove the global mise config merges into what each environment should get.
#
# ~/.config/mise/config.toml is one shared base merged with exactly one variant,
# selected by the container fact. Two things can go wrong and neither is visible
# in a green apply: the merge can stop producing valid TOML, and the split can
# drift so a worker inherits a rust toolchain or a host loses one.
#
# The assertions go through `mise` itself, not a TOML parser. mise is what reads
# this file, and its own view is the only one that decides whether the split
# worked -- a file can parse and still declare nothing mise recognizes.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/mise-config-merge.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'mise-config-merge: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'mise-config-merge: ok - %s\n' "$*"; }

command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is required on PATH'
command -v mise >/dev/null 2>&1 || fail 'mise is required on PATH'

mkdir -p "$scratch/target" "$scratch/bin" "$scratch/home" "$scratch/data" "$scratch/cache"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"

# `cat` renders one TARGET, which is what sets .chezmoi.sourceFile; the template
# reads its sibling fragments relative to that. A stdin execute-template leaves it
# empty and the fragment read fails -- the mistake worth pinning here.
render() {
  (
    cd -- "$repo_root"
    PATH="$scratch/bin:$PATH" chezmoi \
      --config "$scratch/empty.toml" \
      --source "$repo_root" \
      --destination "$scratch/target" \
      --override-data '{"chezmoi":{"os":"linux","arch":"amd64","username":"fx","osRelease":{"id":"fedora"},"homeDir":"'"$scratch"'/home"},"renderOverrides":{"container":'"$1"'}}' \
      cat "$scratch/target/.config/mise/config.toml"
  )
}

# -C "$scratch" matters: mise walks up from the working directory and would
# otherwise merge this repository's own mise.toml into the answer, which is not
# the file under test. The row is selected by path for the same reason.
tools_of() {
  MISE_DATA_DIR="$scratch/data" MISE_CACHE_DIR="$scratch/cache" \
    MISE_GLOBAL_CONFIG_FILE="$1" mise -C "$scratch" config ls --no-header 2>/dev/null |
    awk -v want="$1" '$1 == want { $1 = ""; print }' |
    tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort
}

render true >"$scratch/container.toml" || fail 'the container variant does not render'
render false >"$scratch/baremetal.toml" || fail 'the baremetal variant does not render'
pass 'both variants render'

# --- The worker baseline. node and python and mise's own internals; nothing else.
got=$(tools_of "$scratch/container.toml")
want=$(printf '%s\n' node python pipx usage | sort)
[[ "$got" == "$want" ]] || fail "the container tool set is not the worker baseline.
  got:  $(tr '\n' ' ' <<<"$got")
  want: $(tr '\n' ' ' <<<"$want")"
pass 'the container variant declares exactly node, python, pipx and usage'

# aube is the clean-install failure (its attestation names aubepkg/aube while mise
# resolves jdx/aube), so it must not reach an image build -- and neither may the
# npm package_manager setting that depends on it.
grep -q 'aube' "$scratch/container.toml" \
  && fail 'aube must not appear in the container variant; a clean install of it fails'
pass 'aube and its npm package_manager setting are host-only'

# --- The host keeps everything it had. This is the regression that would be
# silent: a worker gaining a toolchain is obvious, a host losing one is not.
host_tools=$(tools_of "$scratch/baremetal.toml")
for t in aube go ruby rust yarn gcloud; do
  grep -qx "$t" <<<"$host_tools" || fail "$t must still be in the host tool set, and is not"
done
grep -q 'package_manager = "aube"' "$scratch/baremetal.toml" \
  || fail 'the host must still declare aube as its npm package manager'
pass "the host variant keeps its full tool set ($(wc -l <<<"$host_tools") entries)"

# --- Both resolve to real versions. A file mise parses but cannot resolve is a
# build that fails at `mise install`, not at render.
for variant in container baremetal; do
  MISE_DATA_DIR="$scratch/data" MISE_CACHE_DIR="$scratch/cache" \
    MISE_GLOBAL_CONFIG_FILE="$scratch/$variant.toml" \
    mise -C "$scratch" install --dry-run >/dev/null 2>&1 \
    || fail "mise cannot resolve every tool in the $variant variant"
done
pass 'mise resolves every tool in both variants'

# --- The array-of-tables round trip. toToml rewrites ruby's inline-table array as
# [[tools.ruby]]; both declared versions must survive, since that rewrite is the
# one place the merge could quietly lose data.
ruby_versions=$(grep -A2 '\[\[tools.ruby\]\]' "$scratch/baremetal.toml" | grep -c 'version =')
((ruby_versions == 2)) \
  || fail "both ruby versions must survive the toToml rewrite; found $ruby_versions"
pass 'the ruby array-of-tables rewrite is semantics-preserving'

printf 'mise-config-merge: OK\n'
