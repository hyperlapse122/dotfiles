#!/usr/bin/env bash
# Hermetic MX Master 4 haptic event-contract tests (omp).
#
# omp's mxm4-haptic plugin is a bundled TypeScript extension whose event
# waveforms are declared in its package.json (the omp analog of the retired
# Claude/Codex hooks.json manifests). This renders that manifest per POSIX host
# and asserts it carries the haptic.omp-configured waveform contract. The
# runtime event-delivery path (plugin -> daemon) is exercised by
# test-omp-real-plugin.sh and test-mxm4-haptic-provision.sh.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/mxm4-haptic-hooks.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/target" "$scratch/bin"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod +x "$scratch/bin/op"
chezmoi_bin=$(type -P chezmoi)

fail() { printf 'mxm4-haptic hook events: %s\n' "$*" >&2; exit 1; }

render() {
  local os=$1 input=$2 output=$3
  env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" \
      --destination "$scratch/target" --override-data "{\"chezmoi\":{\"os\":\"$os\"}}" \
      execute-template <"$input" >"$output"
}

omp_tmpl="$repo_root/dot_local/share/omp-plugins/plugins/mxm4-haptic/package.json.tmpl"

for os in linux darwin; do
  manifest="$scratch/omp-$os.json"
  render "$os" "$omp_tmpl" "$manifest"
  node - "$manifest" "$os" <<'NODE'
const fs = require("node:fs");
const [manifest, os] = process.argv.slice(2);
const parsed = JSON.parse(fs.readFileSync(manifest, "utf8"));
const waveforms = parsed?.mxm4Haptic?.waveforms;
if (!waveforms) throw new Error(`${os}: omp manifest missing mxm4Haptic.waveforms`);
const canonical = new Set([
  "SHARP STATE CHANGE", "DAMP STATE CHANGE", "SHARP COLLISION", "DAMP COLLISION",
  "SUBTLE COLLISION", "HAPPY ALERT", "ANGRY ALERT", "COMPLETED", "SQUARE", "WAVE",
  "FIREWORK", "MAD", "KNOCK", "JINGLE", "RINGING", "WHISPER COLLISION",
]);
for (const event of ["settled", "failed", "question"]) {
  const waveform = waveforms[event];
  if (!waveform) throw new Error(`${os}: omp ${event} waveform is absent`);
  if (!canonical.has(waveform)) throw new Error(`${os}: omp ${event} waveform ${waveform} is not a known mxm4-haptic waveform`);
}
if (!parsed?.omp?.extensions?.includes("./dist/index.js")) {
  throw new Error(`${os}: omp manifest missing its bundled haptic extension`);
}
NODE
done

printf '%s\n' 'mxm4-haptic hook event tests passed'
