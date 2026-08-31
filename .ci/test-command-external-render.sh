#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/command-external-render.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/target"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf '[data]\n' >"$scratch/empty.toml"

fail() { printf 'command external render: %s\n' "$*" >&2; exit 1; }

[[ ! -f "$repo_root/.chezmoiscripts/00-tools/run_onchange_after_codegraph.sh.tmpl" ]] || {
  fail "run_onchange_after_codegraph.sh.tmpl should be deleted"
}

platforms=(
  "linux:amd64"
  "linux:arm64"
  "darwin:arm64"
)

for plat in "${platforms[@]}"; do
  IFS=":" read -r os arch <<<"$plat"
  out="$scratch/externals-$os-$arch.toml"
  for ext in "$repo_root/.chezmoiexternals"/*.toml; do
    env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" --destination "$scratch/target" \
      --override-data "{\"chezmoi\":{\"os\":\"$os\",\"arch\":\"$arch\"}}" \
      execute-template <"$ext" >>"$out"
  done

  if grep -E 'targetPath\s*=\s*.*\.local/bin/' "$out"; then
    fail "found targetPath starting with .local/bin/ in $out"
  fi

  grep -F '.local/share/chezmoi-commands/incomplete/' "$out" >/dev/null || {
    fail "missing .local/share/chezmoi-commands/incomplete/ targets in $out"
  }
done

rendered_flutter="$scratch/flutter.sh"
rendered_kitty="$scratch/kitty.sh"

env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" --destination "$scratch/target" \
  --override-data '{"chezmoi":{"os":"linux","arch":"amd64"}}' \
  execute-template <"$repo_root/.chezmoiscripts/00-tools/run_onchange_after_flutter.sh.tmpl" >"$rendered_flutter"

if grep -E '\$BIN_DIR|pruned=' "$rendered_flutter"; then
  fail "flutter script still contains public link or prune operations"
fi

env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" --destination "$scratch/target" \
  --override-data '{"chezmoi":{"os":"linux","arch":"amd64"}}' \
  execute-template <"$repo_root/.chezmoiscripts/00-tools/run_onchange_before_kitty.sh.tmpl" >"$rendered_kitty"

if grep -E '\$BIN_DIR|rm -rf -- "\$d"' "$rendered_kitty"; then
  fail "kitty script still contains public link or prune operations"
fi

printf '%s\n' 'command external render validation passed'
