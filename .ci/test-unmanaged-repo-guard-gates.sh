#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/unmanaged-repo-guard-gates.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/target" "$scratch/bin"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod +x "$scratch/bin/op"
chezmoi_bin=$(type -P chezmoi)

# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"

fail() { printf 'unmanaged-repo-guard gates: %s\n' "$*" >&2; exit 1; }

posix_reconcile=.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl
guard_manifest=dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/package.json.tmpl
guard_tsconfig=.ci/tsconfig.unmanaged-repo-guard.json
for path in "$posix_reconcile" "$guard_manifest" "$guard_tsconfig" \
  dot_local/share/omp-plugins/dot_omp-plugin/marketplace.json \
  dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/index.ts \
  dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/triggers.ts \
  dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/target.ts \
  dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/probe.ts \
  dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/reason.ts; do
  require_file "$repo_root" "$scratch" "$chezmoi_bin" "$path"
done

# Render the production ignore template with only its fact provider replaced by
# deterministic fixture facts. This exercises the real path gates without
# consulting this runner's container markers or desktop session.

omp_market=.local/share/omp-plugins/dot_omp-plugin/marketplace.json
guard_tree=.local/share/omp-plugins/plugins/unmanaged-repo-guard
haptic_tree=.local/share/omp-plugins/plugins/mxm4-haptic

# AE8 / R18: in a container the guard tree and the shared catalog stay
# reachable while the hardware-bound haptic plugin does not.
container_ignore="$scratch/ignore-linux-container"
render_ignore "$repo_root" "$scratch" "$chezmoi_bin" linux true "$container_ignore"
assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$container_ignore" eligible "$guard_tree" 'linux container'
assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$container_ignore" ignored "$haptic_tree" 'linux container'
assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$container_ignore" eligible "$omp_market" 'linux container'

row_present() { grep -F "$2\\t$3" "$1" >/dev/null; }

# Container host: the guard row survives while the haptic row is filtered out.
render_reconciler "$repo_root" "$scratch" "$chezmoi_bin" linux true "$posix_reconcile" "$scratch/reconcile-linux-container.sh"
row_present "$scratch/reconcile-linux-container.sh" unmanaged-repo-guard h82-dotfiles ||
  fail 'container reconciler dropped the unmanaged-repo-guard row'
! row_present "$scratch/reconcile-linux-container.sh" mxm4-haptic h82-dotfiles ||
  fail 'container reconciler unexpectedly rendered the mxm4-haptic row'

# Non-container Linux: both rows present.
render_reconciler "$repo_root" "$scratch" "$chezmoi_bin" linux false "$posix_reconcile" "$scratch/reconcile-linux-host.sh"
row_present "$scratch/reconcile-linux-host.sh" unmanaged-repo-guard h82-dotfiles ||
  fail 'non-container reconciler dropped the unmanaged-repo-guard row'
row_present "$scratch/reconcile-linux-host.sh" mxm4-haptic h82-dotfiles ||
  fail 'non-container reconciler dropped the mxm4-haptic row'

# macOS: both rows present (the h82-dotfiles marketplace lists darwin).
render_reconciler "$repo_root" "$scratch" "$chezmoi_bin" darwin false "$posix_reconcile" "$scratch/reconcile-darwin.sh"
row_present "$scratch/reconcile-darwin.sh" unmanaged-repo-guard h82-dotfiles ||
  fail 'macOS reconciler dropped the unmanaged-repo-guard row'
row_present "$scratch/reconcile-darwin.sh" mxm4-haptic h82-dotfiles ||
  fail 'macOS reconciler dropped the mxm4-haptic row'

# Compatibility invariant: a plugin row omitting `container` entirely renders
# the exact same 5-tab-field row shape as before this change — no 6th field,
# no altered eligibility for a row that never opted into the new key. Replace
# the whole agents.omp.plugins list (chezmoi/mergo replaces arrays wholesale
# rather than merging them) so the fixture is isolated from the real rows.
render_override() {
  local os=$1 template=$2 override=$3 output=$4
  env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" \
      --destination "$scratch/target" --override-data "$override" \
      execute-template <"$repo_root/$template" >"$output"
}
render_override linux "$posix_reconcile" \
  '{"chezmoi":{"os":"linux"},"agents":{"omp":{"plugins":[{"name":"mxm4-haptic","marketplace":"h82-dotfiles"}]}}}' \
  "$scratch/reconcile-omitted-container.sh"
node -e '
  const fs = require("node:fs");
  const [path] = process.argv.slice(1);
  const text = fs.readFileSync(path, "utf8");
  const m = text.match(/PLUGINS=\(\s*([\s\S]*?)\n\)/);
  if (!m) throw new Error("omitted-container fixture rendered no PLUGINS array");
  const rows = m[1].split("\n").map(l => l.trim()).filter(Boolean);
  if (rows.length !== 1) throw new Error(`expected exactly one row, got ${rows.length}: ${JSON.stringify(rows)}`);
  const row = rows[0].replace(/^"|"$/g, "");
  const fields = row.split("\\t");
  if (fields.length !== 5) throw new Error(`a row omitting container must render the unchanged 5-field shape, got ${fields.length}: ${row}`);
  const [name, market, kind, , strict] = fields;
  if (name !== "mxm4-haptic" || market !== "h82-dotfiles" || kind !== "localDir" || strict !== "true") {
    throw new Error(`a row omitting container rendered an unexpected shape: ${row}`);
  }
' "$scratch/reconcile-omitted-container.sh"

# An invalid per-row container value fails the render and names both the key
# and the offending value.
if env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" "$chezmoi_bin" \
  --config "$scratch/empty.toml" --source "$repo_root" --destination "$scratch/target" \
  --override-data '{"chezmoi":{"os":"linux"},"agents":{"omp":{"plugins":[{"name":"unmanaged-repo-guard","marketplace":"h82-dotfiles","container":"maybe"}]}}}' \
  execute-template <"$repo_root/$posix_reconcile" \
  >"$scratch/invalid-container.out" 2>"$scratch/invalid-container.err"; then
  fail 'reconciler accepted an invalid per-plugin container value'
fi
grep -F 'container' "$scratch/invalid-container.err" >/dev/null ||
  fail 'invalid-container rejection did not name the container key'
grep -F 'maybe' "$scratch/invalid-container.err" >/dev/null ||
  fail 'invalid-container rejection did not name the offending value'

# The rendered plugin manifest has the three required fields.
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$repo_root/$guard_manifest" "$scratch/manifest.json"
node -e '
  const fs = require("node:fs");
  const [path] = process.argv.slice(1);
  const manifest = JSON.parse(fs.readFileSync(path, "utf8"));
  if (manifest.name !== "@h82/omp-unmanaged-repo-guard") throw new Error(`unexpected name: ${manifest.name}`);
  if (manifest.type !== "module") throw new Error(`unexpected type: ${manifest.type}`);
  if (!Array.isArray(manifest.omp?.extensions) || manifest.omp.extensions.length !== 1 || manifest.omp.extensions[0] !== "./src/index.ts") {
    throw new Error(`unexpected omp.extensions: ${JSON.stringify(manifest.omp?.extensions)}`);
  }
' "$scratch/manifest.json"

# The manifest render fails when agents.unmanagedRepoGuard.probeTimeoutMs is
# missing or out of range. --override-data deep-merges maps onto the real
# agents.yaml data (it cannot delete a key already present there), so the
# "missing key" fixture substitutes the manifest's own data-source expression
# with a literal dict, mirroring render_ignore/render_reconciler's anchor
# substitution above rather than fighting the merge semantics.
render_manifest_fixture() {
  local guard_expr=$1 output=$2 variant
  variant="$scratch/manifest-fixture-$RANDOM.tmpl"
  node -e '
    const fs = require("node:fs");
    const [sourcePath, outputPath, guardExpr] = process.argv.slice(1);
    const source = fs.readFileSync(sourcePath, "utf8");
    const needle = `{{- $guard := .agents.unmanagedRepoGuard -}}`;
    if (source.split(needle).length !== 2) throw new Error("manifest guard-data anchor changed");
    fs.writeFileSync(outputPath, source.replace(needle, `{{- $guard := ${guardExpr} -}}`));
  ' "$repo_root/$guard_manifest" "$variant" "$guard_expr"
  render "$repo_root" "$scratch" "$chezmoi_bin" linux "$variant" "$output" 2>"$output.err"
}
if render_manifest_fixture 'dict "cacheTtlMs" 300000' "$scratch/manifest-missing.json"; then
  fail 'manifest render accepted a missing probeTimeoutMs'
fi
grep -F 'probeTimeoutMs' "$scratch/manifest-missing.json.err" >/dev/null ||
  fail 'missing-probeTimeoutMs rejection did not name the key'
grep -F 'missing' "$scratch/manifest-missing.json.err" >/dev/null ||
  fail 'missing-probeTimeoutMs rejection did not say it was missing'

if render_manifest_fixture 'dict "probeTimeoutMs" 5000000 "cacheTtlMs" 300000' "$scratch/manifest-oor.json"; then
  fail 'manifest render accepted an out-of-range probeTimeoutMs'
fi
grep -F 'probeTimeoutMs' "$scratch/manifest-oor.json.err" >/dev/null ||
  fail 'out-of-range rejection did not name the key'
grep -F 'out of range' "$scratch/manifest-oor.json.err" >/dev/null ||
  fail 'out-of-range rejection did not say it was out of range'

# R20: typecheck the guard's TypeScript. It lives outside packages/, so the
# workspace-wide ts-workspace CI job never reaches it. Resolve tsc the way the
# repo's other scripts resolve toolchain binaries: an already-activated bare
# command wins, otherwise fall back to `mise exec`; a host that can supply
# neither gets a clear skip notice rather than a failure.
tsc_via_mise=0
if command -v tsc >/dev/null 2>&1; then
  tsc_via_mise=0
elif command -v mise >/dev/null 2>&1; then
  tsc_via_mise=1
else
  printf 'unmanaged-repo-guard gates: notice: skipping guard typecheck — tsc is not on PATH and mise cannot supply it\n' >&2
  tsc_via_mise=-1
fi
if [[ $tsc_via_mise -ge 0 ]]; then
  if [[ $tsc_via_mise -eq 1 ]]; then
    ( cd "$repo_root" && mise exec -- tsc --noEmit -p "$guard_tsconfig" ) ||
      fail 'guard typecheck failed'
  else
    ( cd "$repo_root" && tsc --noEmit -p "$guard_tsconfig" ) ||
      fail 'guard typecheck failed'
  fi
fi

printf '%s\n' 'unmanaged-repo-guard render gates passed'
