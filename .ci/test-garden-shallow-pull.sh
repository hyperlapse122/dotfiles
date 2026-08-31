#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/test-garden-shallow.XXXXXX")
chmod 700 "$scratch"
trap 'rm -rf -- "$scratch"' EXIT

command -v garden >/dev/null 2>&1 || {
  printf 'test-garden-shallow-pull: garden not on PATH\n' >&2
  exit 1
}

mkdir -p "$scratch/remote.git"
git -C "$scratch/remote.git" init --bare --initial-branch=main
git -C "$scratch/remote.git" symbolic-ref HEAD refs/heads/main

dummy_work="$scratch/dummy_work"
mkdir -p "$dummy_work"
git -C "$dummy_work" init --initial-branch=main
git -C "$dummy_work" config user.email "test@example.com"
git -C "$dummy_work" config user.name "Test"
echo "1" > "$dummy_work/file" && git -C "$dummy_work" add file && git -C "$dummy_work" commit -m "c1"
echo "2" > "$dummy_work/file" && git -C "$dummy_work" commit -am "c2"
echo "3" > "$dummy_work/file" && git -C "$dummy_work" commit -am "c3"
git -C "$dummy_work" remote add origin "$scratch/remote.git"
git -C "$dummy_work" push -u origin main
rm -rf "$dummy_work"

cat << EOF > "$scratch/garden.yaml"
garden:
  root: $scratch/src
templates:
  shallow:
    depth: 1
    single-branch: false
trees:
  test-tree:
    templates: shallow
    path: test-host/test-group/test-tree
    url: file://$scratch/remote.git
commands:
  setup-upstream: |
    git -C "\${TREE_PATH}" remote set-head origin --auto
  unshallow: |
    if git -C "\${TREE_PATH}" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
      printf 'unshallow: fetching full history for %s...\n' "\${TREE_NAME}"
      git -C "\${TREE_PATH}" fetch --unshallow
    else
      printf 'unshallow: %s is already unshallow\n' "\${TREE_NAME}"
    fi
EOF

garden --config "$scratch/garden.yaml" grow test-tree
tree_path="$scratch/src/test-host/test-group/test-tree"

is_shallow=$(git -C "$tree_path" rev-parse --is-shallow-repository)
if [ "$is_shallow" != "true" ]; then
  printf 'test-garden-shallow-pull: expected shallow repository, got %s\n' "$is_shallow" >&2
  exit 1
fi

commit_count=$(git -C "$tree_path" rev-list --count HEAD)
if [ "$commit_count" -ne 1 ]; then
  printf 'test-garden-shallow-pull: expected 1 commit on shallow clone, got %d\n' "$commit_count" >&2
  exit 1
fi

fetch_refspec=$(git -C "$tree_path" config --get-all remote.origin.fetch)
if [ "$fetch_refspec" != "+refs/heads/*:refs/remotes/origin/*" ]; then
  printf 'test-garden-shallow-pull: expected full refspec, got %s\n' "$fetch_refspec" >&2
  exit 1
fi

garden --config "$scratch/garden.yaml" cmd test-tree setup-upstream
origin_head=$(git -C "$tree_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)
if [ "$origin_head" != "refs/remotes/origin/main" ]; then
  printf 'test-garden-shallow-pull: setup-upstream failed on shallow clone\n' >&2
  exit 1
fi

sed \
  -e "s|\$HOME/src|$scratch/src|g" \
  -e "s|\$HOME/.config/garden/garden.yaml|$scratch/garden.yaml|g" \
  "$repo_root/dot_local/bin/executable_src-audit" > "$scratch/src-audit"
chmod +x "$scratch/src-audit"
HOME="$scratch" "$scratch/src-audit" >"$scratch/audit.out" 2>&1 || {
  printf 'test-garden-shallow-pull: src-audit failed on shallow checkout\n' >&2
  cat "$scratch/audit.out" >&2
  exit 1
}
if grep -E 'broken|unmanaged' "$scratch/audit.out" | grep -v '##' | grep -v '(none)' >/dev/null; then
  printf 'test-garden-shallow-pull: src-audit reported false drift on shallow checkout\n' >&2
  cat "$scratch/audit.out" >&2
  exit 1
fi

unshallow_out=$(garden --config "$scratch/garden.yaml" cmd test-tree unshallow 2>&1)
if ! printf '%s' "$unshallow_out" | grep -F "fetching full history for test-tree" >/dev/null; then
  printf 'test-garden-shallow-pull: unexpected unshallow output: %s\n' "$unshallow_out" >&2
  exit 1
fi
is_shallow_after=$(git -C "$tree_path" rev-parse --is-shallow-repository)
if [ "$is_shallow_after" != "false" ]; then
  printf 'test-garden-shallow-pull: repository still shallow after unshallow\n' >&2
  exit 1
fi

commit_count_after=$(git -C "$tree_path" rev-list --count HEAD)
if [ "$commit_count_after" -ne 3 ]; then
  printf 'test-garden-shallow-pull: expected 3 commits after unshallow, got %d\n' "$commit_count_after" >&2
  exit 1
fi

unshallow_second=$(garden --config "$scratch/garden.yaml" cmd test-tree unshallow 2>&1)
if ! printf '%s' "$unshallow_second" | grep -F "is already unshallow" >/dev/null; then
  printf 'test-garden-shallow-pull: unshallow second run did not report already unshallow\n' >&2
  printf '%s\n' "$unshallow_second" >&2
  exit 1
fi

chezmoi --source "$repo_root" decrypt "$repo_root/dot_config/garden/encrypted_readonly_garden.yaml.asc" > "$scratch/real_garden.yaml"
garden --config "$scratch/real_garden.yaml" ls -v >/dev/null 2>&1 || {
  printf 'test-garden-shallow-pull: real garden.yaml failed to parse with garden ls\n' >&2
  exit 1
}
grep -F 'templates:' "$scratch/real_garden.yaml" >/dev/null || {
  printf 'test-garden-shallow-pull: templates missing from real garden.yaml\n' >&2
  exit 1
}
grep -F 'shallow:' "$scratch/real_garden.yaml" >/dev/null || {
  printf 'test-garden-shallow-pull: shallow template missing from real garden.yaml\n' >&2
  exit 1
}
grep -F 'unshallow:' "$scratch/real_garden.yaml" >/dev/null || {
  printf 'test-garden-shallow-pull: unshallow command missing from real garden.yaml\n' >&2
  exit 1
}

printf 'test-garden-shallow-pull: all tests passed\n'
