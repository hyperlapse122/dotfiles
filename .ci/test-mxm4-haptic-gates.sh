#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/mxm4-haptic-gates.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/target" "$scratch/bin"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod +x "$scratch/bin/op"
chezmoi_bin=$(type -P chezmoi)

fail() { printf 'mxm4-haptic gates: %s\n' "$*" >&2; exit 1; }
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"
render_remove() {
  local repo_root=$1 scratch=$2 chezmoi_bin=$3 os=$4 container=$5 output=$6 variant
  variant="$scratch/remove-$os-$container.tmpl"
  write_fact_stub "$repo_root/.chezmoiremove" "$variant" "$container"
  render "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$variant" "$output"
}

posix_build=.chezmoiscripts/60-build/run_after_build-mxm4-haptic.sh.tmpl
posix_reconcile=.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl
for path in .chezmoiignore .chezmoiremove "$posix_build" "$posix_reconcile" \
  dot_local/share/omp-plugins/dot_omp-plugin/marketplace.json.tmpl \
  dot_local/share/omp-plugins/plugins/mxm4-haptic/package.json.tmpl \
  dot_config/systemd/user/mxm4-hapticd.service.tmpl \
  dot_config/systemd/user/mxm4-haptic-notify.service.tmpl \
  Library/LaunchAgents/dev.h82.mxm4-hapticd.plist; do
  require_file "$repo_root" "$scratch" "$chezmoi_bin" "$path"
done

omp_plugins=.local/share/omp-plugins

omp_market=.local/share/omp-plugins/.omp-plugin/marketplace.json
omp_plugin=.local/share/omp-plugins/plugins/mxm4-haptic/package.json
linux_daemon=.config/systemd/user/mxm4-hapticd.service
linux_notify=.config/systemd/user/mxm4-haptic-notify.service
mac_daemon=Library/LaunchAgents/dev.h82.mxm4-hapticd.plist

# The daemon is cross-platform, so the OMP haptic plugin and the daemon manifest
# deploy on every desktop OS; only the startup definitions stay OS-specific
# (systemd on Linux, launchd on macOS).
for os in linux darwin; do
  rendered_ignore="$scratch/ignore-$os-host"
  render_ignore "$repo_root" "$scratch" "$chezmoi_bin" "$os" false "$rendered_ignore"
  for path in "$omp_market" "$omp_plugin"; do
    assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$rendered_ignore" eligible "$path" "$os host"
  done
  if [[ "$os" == linux ]]; then
    for path in "$linux_daemon" "$linux_notify"; do assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$rendered_ignore" eligible "$path" "$os host"; done
    assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$rendered_ignore" ignored "$mac_daemon" "$os host"
  else
    for path in "$linux_daemon" "$linux_notify"; do assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$rendered_ignore" ignored "$path" "$os host"; done
    assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$rendered_ignore" eligible "$mac_daemon" "$os host"
  fi
done

# Native autostart/launch definitions: the macOS LaunchAgent must keep its
# login autostart + keepalive semantics.
plist="$repo_root/Library/LaunchAgents/dev.h82.mxm4-hapticd.plist"
grep -A1 '<key>RunAtLoad</key>' "$plist" | grep -q '<true/>' || fail 'macOS LaunchAgent lost RunAtLoad autostart'
grep -A1 '<key>KeepAlive</key>' "$plist" | grep -q '<true/>' || fail 'macOS LaunchAgent lost KeepAlive'
grep -F '"$HOME/.local/bin/mxm4-hapticd"' "$plist" >/dev/null || fail 'macOS LaunchAgent lost its per-user daemon path'

container_ignore="$scratch/ignore-linux-container"
render_ignore "$repo_root" "$scratch" "$chezmoi_bin" linux true "$container_ignore"
for path in "$omp_plugins" "$omp_market" "$omp_plugin" "$linux_daemon" "$linux_notify" "$mac_daemon"; do
  assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$container_ignore" ignored "$path" 'linux container'
done
assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$container_ignore" ignored .chezmoiscripts/60-build/run_after_build-mxm4-haptic.sh 'linux container'
# The phase-70 omp reconciler remains eligible in containers to maintain
# keep-marked marketplaces and remove the retired legacy extension.
assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$container_ignore" eligible .chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh 'linux container migration'
# i-have-adhd is now a skill-only, always-on integration: the skill tree and
# the APPEND_SYSTEM.md prompt append deploy in containers exactly as they do
# on managed hosts.
assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$container_ignore" eligible .agents/skills/i-have-adhd 'linux container adhd skill'
assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$container_ignore" eligible .omp/agent/APPEND_SYSTEM.md 'linux container adhd always-on prompt'
jetson_ignore="$scratch/ignore-linux-jetson"
render_ignore "$repo_root" "$scratch" "$chezmoi_bin" linux false "$jetson_ignore" true
for path in "$omp_plugins" "$omp_market" "$omp_plugin" "$linux_daemon" "$linux_notify"; do
  assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$jetson_ignore" ignored "$path" 'linux jetson'
done
assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$jetson_ignore" ignored .chezmoiscripts/60-build/run_after_build-mxm4-haptic.sh 'linux jetson'
assert_gate "$repo_root" "$scratch" "$chezmoi_bin" "$jetson_ignore" eligible .chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh 'linux jetson updater'


host_remove="$scratch/remove-linux-host"
container_remove="$scratch/remove-linux-container"
render_remove "$repo_root" "$scratch" "$chezmoi_bin" linux false "$host_remove"
render_remove "$repo_root" "$scratch" "$chezmoi_bin" linux true "$container_remove"
LC_ALL=C sort "$host_remove" >"$scratch/remove-linux-host.sorted"
LC_ALL=C sort "$container_remove" >"$scratch/remove-linux-container.sorted"
comm -13 "$scratch/remove-linux-host.sorted" "$scratch/remove-linux-container.sorted" >"$scratch/container-only-removals"
printf '%s\n' "$omp_market" >"$scratch/expected-container-only-removals"
if ! cmp -s "$scratch/expected-container-only-removals" "$scratch/container-only-removals"; then
  diff -u "$scratch/expected-container-only-removals" "$scratch/container-only-removals" >&2 || true
  fail 'container removal must add only the stranded OMP marketplace catalog cleanup'
fi

# Template guards are a second line of defense: exactly one native build and
# one reconciliation implementation renders on each host OS.
for os in linux darwin; do
  render "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$repo_root/$posix_build" "$scratch/build-$os.sh"
  render_reconciler "$repo_root" "$scratch" "$chezmoi_bin" "$os" false "$posix_reconcile" "$scratch/reconcile-$os.sh"
  [[ -s "$scratch/build-$os.sh" ]] || fail "$os build guard mismatch"
  [[ -s "$scratch/reconcile-$os.sh" ]] || fail "$os reconcile guard mismatch"
  grep -F '.omp/agent/extensions/mxm4-haptic.ts' "$scratch/reconcile-$os.sh" >/dev/null || fail "$os migration is absent"
  grep -F 'mxm4-haptic\th82-dotfiles' "$scratch/reconcile-$os.sh" >/dev/null || fail "$os OMP haptic row is absent"
  if [[ "$os" == linux ]]; then
    grep -F 'systemctl --user' "$scratch/build-$os.sh" >/dev/null || fail 'Linux systemd startup is absent'
  else
    grep -F 'launchctl bootstrap' "$scratch/build-$os.sh" >/dev/null || fail 'macOS launchd startup is absent'
  fi
done

render_reconciler "$repo_root" "$scratch" "$chezmoi_bin" linux true "$posix_reconcile" "$scratch/reconcile-linux-container.sh"
! grep -F 'mxm4-haptic\th82-dotfiles' "$scratch/reconcile-linux-container.sh" >/dev/null || fail 'container rendered the OMP haptic row'
! grep -F 'i-have-adhd\ti-have-adhd\tlocalArchive' "$scratch/reconcile-linux-container.sh" >/dev/null || fail 'container still renders i-have-adhd plugin row'
grep -F '.omp/agent/extensions/mxm4-haptic.ts' "$scratch/reconcile-linux-container.sh" >/dev/null || fail 'container migration is absent'
render_reconciler "$repo_root" "$scratch" "$chezmoi_bin" linux false "$posix_reconcile" "$scratch/reconcile-linux-jetson.sh" true
! grep -F 'mxm4-haptic\th82-dotfiles' "$scratch/reconcile-linux-jetson.sh" >/dev/null || fail 'jetson rendered the OMP haptic row'
grep -F '.omp/agent/extensions/mxm4-haptic.ts' "$scratch/reconcile-linux-jetson.sh" >/dev/null || fail 'jetson migration is absent'

# Container and Jetson skip h82-dotfiles entirely, so there the removal set
# keeps it and cleans up the orphan.
removed_marketplaces() {
  awk '/^MARKETPLACES_REMOVED=\($/{flag=1;next} /^\)/{flag=0} flag' "$1"
}
render_reconciler "$repo_root" "$scratch" "$chezmoi_bin" linux false "$posix_reconcile" "$scratch/reconcile-linux-host.sh"
grep -F 'unmanaged-repo-guard\th82-dotfiles' "$scratch/reconcile-linux-host.sh" >/dev/null || fail 'host lost the unmanaged-repo-guard uninstall row'
removed_marketplaces "$scratch/reconcile-linux-host.sh" >"$scratch/removed-host"
grep -F 'i-have-adhd' "$scratch/removed-host" >/dev/null || fail 'host lost the i-have-adhd marketplace removal'
! grep -qF 'h82-dotfiles' "$scratch/removed-host" || fail 'host removes the surviving h82-dotfiles marketplace'
removed_marketplaces "$scratch/reconcile-linux-container.sh" >"$scratch/removed-container"
grep -F 'h82-dotfiles' "$scratch/removed-container" >/dev/null || fail 'container keeps the orphaned h82-dotfiles marketplace'
removed_marketplaces "$scratch/reconcile-linux-jetson.sh" >"$scratch/removed-jetson"
grep -F 'h82-dotfiles' "$scratch/removed-jetson" >/dev/null || fail 'jetson keeps the orphaned h82-dotfiles marketplace'


# Every deployed manifest must reject a real invalid value during rendering.
# Its observable rejection whitelist must exactly match both implementations.
invalid=NOT_A_REAL_WAVEFORM
render_invalid() {
  local name=$1 template=$2 override=$3
  if env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" "$chezmoi_bin" \
    --config "$scratch/empty.toml" --source "$repo_root" --destination "$scratch/target" \
    --override-data "$override" execute-template <"$repo_root/$template" \
    >"$scratch/$name.invalid.out" 2>"$scratch/$name.invalid.err"; then
    fail "$name accepted invalid waveform $invalid"
  fi
  grep -F "$invalid" "$scratch/$name.invalid.err" >/dev/null || fail "$name rejection did not identify invalid value"
  grep -F 'valid names' "$scratch/$name.invalid.err" >/dev/null || fail "$name rejection omitted its whitelist"
}
render_invalid omp dot_local/share/omp-plugins/plugins/mxm4-haptic/package.json.tmpl "{\"haptic\":{\"omp\":{\"settled\":\"$invalid\"}}}"

node - "$repo_root/packages/mxm4-haptic/src/index.ts" "$repo_root/crates/mxm4-haptic/src/lib.rs" "$scratch/omp.invalid.err" <<'NODE'
const fs = require('node:fs');
const [tsPath, rustPath, ...errors] = process.argv.slice(2);
const ts = [...fs.readFileSync(tsPath, 'utf8').matchAll(/\["([A-Z][A-Z ]+)",\s*\d+\]/g)].map((m) => m[1]);
const rust = [...fs.readFileSync(rustPath, 'utf8').matchAll(/\("([A-Z][A-Z ]+)",\s*(?:0x[0-9A-Fa-f]+|\d+)\)/g)].map((m) => m[1]);
const canonical = [...new Set(ts)].sort();
if (canonical.length !== 16 || JSON.stringify(canonical) !== JSON.stringify([...new Set(rust)].sort())) throw new Error('TypeScript/Rust waveform names diverge');
for (const errorPath of errors) {
  const text = fs.readFileSync(errorPath, 'utf8');
  const match = text.match(/valid names(?: \([^\n]*?\))?:\s*([A-Z][A-Z ,]*)/);
  if (!match) throw new Error(`${errorPath}: could not parse rendered rejection whitelist`);
  const deployed = [...new Set(match[1].split(',').map((name) => name.trim()).filter(Boolean))].sort();
  if (JSON.stringify(deployed) !== JSON.stringify(canonical)) throw new Error(`${errorPath}: deployed whitelist diverges from TypeScript/Rust`);
}
NODE

printf '%s\n' 'mxm4-haptic render gates passed'
