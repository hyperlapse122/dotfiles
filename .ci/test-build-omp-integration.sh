#!/usr/bin/env bash
set -euo pipefail
rendered=${1:?usage: test-build-omp-integration.sh RENDERED_SCRIPT}
scratch=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/omp-build-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/bin" "$scratch/source/packages/omp-orca/dist" "$scratch/source/packages/antigravity-sidecar/dist"
printf 'extension artifact\n' >"$scratch/source/packages/omp-orca/dist/dotfiles-orca.js"
printf '#!/usr/bin/env bash\nexit 0\n' >"$scratch/source/packages/antigravity-sidecar/dist/antigravity-sidecar"
printf '#!/usr/bin/env bash\nexit "${BUILD_FAILURE:-0}"\n' >"$scratch/bin/mise"
printf '#!/usr/bin/env bash\nexit 0\n' >"$scratch/bin/bun"
chmod 0700 "$scratch/bin/mise" "$scratch/bin/bun"
sed "s|^SRC=.*$|SRC=\"$scratch/source\"|" "$rendered" >"$scratch/build.sh"
run() { env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" bash "$scratch/build.sh"; }
run
extension="$scratch/home/.local/share/dotfiles-omp/dotfiles-orca.js"
binary="$scratch/home/.local/share/chezmoi-commands/incomplete/antigravity-sidecar/antigravity-sidecar"
cmp "$extension" "$scratch/source/packages/omp-orca/dist/dotfiles-orca.js"
[[ -x "$binary" ]]
run
cp "$binary" "$scratch/previous"
if BUILD_FAILURE=1 run; then exit 1; fi
cmp "$binary" "$scratch/previous"
rm "$extension"
ln -s "$scratch/previous" "$extension"
if run; then exit 1; fi
cmp "$binary" "$scratch/previous"
[[ -L "$extension" ]]
rm "$extension"
rm "$scratch/source/packages/antigravity-sidecar/dist/antigravity-sidecar"
if run; then exit 1; fi
cmp "$binary" "$scratch/previous"
printf 'omp integration build: all cases passed\n'
