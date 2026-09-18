#!/usr/bin/env bash
set -euo pipefail
rendered=${1:?usage: test-build-omp-integration.sh RENDERED_SCRIPT}
bash -n "$rendered"
scratch=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/omp-build-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/bin" "$scratch/source/packages/omp-orca/dist"
printf 'extension artifact\n' >"$scratch/source/packages/omp-orca/dist/dotfiles-orca.js"
cat >"$scratch/bin/mise" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SCRATCH_DIR}/mise.log"
exit "${BUILD_FAILURE:-0}"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$scratch/bin/bun"
chmod 0700 "$scratch/bin/mise" "$scratch/bin/bun"
sed "s|^SRC=.*$|SRC=\"$scratch/source\"|" "$rendered" >"$scratch/build.sh"
run() { env HOME="$scratch/home" SCRATCH_DIR="$scratch" PATH="$scratch/bin:/usr/bin:/bin" bash "$scratch/build.sh"; }
run
extension="$scratch/home/.local/share/dotfiles-omp/dotfiles-orca.js"
cmp "$extension" "$scratch/source/packages/omp-orca/dist/dotfiles-orca.js"
[[ $(grep -c -F 'exec -- vp install --frozen-lockfile' "$scratch/mise.log") -eq 1 ]]
[[ $(grep -c -F 'exec -- vp run build' "$scratch/mise.log") -eq 1 ]]
grep -F -- "-C $scratch/source/packages exec -- vp install --frozen-lockfile" "$scratch/mise.log" >/dev/null
grep -F -- "-C $scratch/source/packages/omp-orca exec -- vp run build" "$scratch/mise.log" >/dev/null
! grep -F 'antigravity-sidecar' "$scratch/mise.log"
cp "$extension" "$scratch/previous"
run
cmp "$extension" "$scratch/previous"
if BUILD_FAILURE=1 run; then exit 1; fi
cmp "$extension" "$scratch/previous"
rm -f "$extension"
ln -s "$scratch/previous" "$extension"
if run; then exit 1; fi
[[ -L "$extension" ]]
cmp "$extension" "$scratch/previous"
rm -f "$extension"
cp "$scratch/previous" "$extension"
rm -f "$scratch/source/packages/omp-orca/dist/dotfiles-orca.js"
if run; then exit 1; fi
cmp "$extension" "$scratch/previous"
printf 'omp integration build: all cases passed\n'
