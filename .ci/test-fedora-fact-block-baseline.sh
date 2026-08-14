#!/usr/bin/env bash
# Prove the standard Fedora x86_64 render stays byte-for-byte at its pre-Jetson
# baseline once the generated facts-sh block is removed. New host facts may grow
# that block; no other rendered control flow may drift (R22).
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/fedora-fact-block-baseline.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/target"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf '[data]\n' >"$scratch/empty.toml"

fail() {
  printf 'fedora-fact-block-baseline: FAIL: %s\n' "$*" >&2
  exit 1
}

command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is required on PATH'
command -v node >/dev/null 2>&1 || fail 'node is required on PATH'

# Render deterministic host facts so hashes are environment-independent.
fixture_root="$scratch/source"
mkdir -p "$fixture_root"
cp -a "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" \
  "$repo_root/.chezmoiscripts" "$repo_root/system" "$fixture_root/"
cat >"$fixture_root/.chezmoitemplates/facts.tmpl" <<'FACTS'
os: linux
distro: fedora
desktop: none
nvidia: false
thinkpad: false
jetson: false
vm: false
virt: false
sddmBreeze: false
gdm: false
fprintdPam: false
headless: false
container: false
sharedHost: false
FACTS

render() {
  local template=$1 output=$2
  (
    cd -- "$fixture_root"
    PATH="$scratch/bin:$PATH" chezmoi \
      --config "$scratch/empty.toml" \
      --source "$PWD" \
      --destination "$scratch/target" \
      --override-data '{"chezmoi":{"os":"linux","arch":"amd64","username":"fedora-fixture","osRelease":{"id":"fedora"}}}' \
      execute-template <"$template"
  ) >"$output"
}

# Replace the exact rendered facts-sh assignment group with a stable marker.
without_facts() {
  local input=$1 output=$2 source_root=$3
  node - "$input" "$output" "$source_root" <<'NODE'
const fs = require("node:fs");
const [input, output, sourceRoot] = process.argv.slice(2);
const source = fs.readFileSync(input, "utf8");
const marker = "# Host facts — GENERATED from .chezmoidata/facts.yaml via\n";
const start = source.indexOf(marker);
let normalized = source;
if (start !== -1) {
  const end = source.indexOf("\n}\n", start);
  if (end === -1) throw new Error(`facts-sh block is unterminated in ${input}`);
  normalized = `${source.slice(0, start)}# <GENERATED FACT BLOCK>\n${source.slice(end + 3)}`;
}
fs.writeFileSync(output, normalized.replaceAll(sourceRoot, "<SOURCE_ROOT>"));
NODE
}

# Pre-Jetson Fedora x86_64 hashes after generated facts are normalized.
declare -A baseline_hashes=(
  [.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl]=14ac92a18bf15de5da62593405c44d3763d0f3d794046d86d00d788b6c43ddf4
  [.chezmoiscripts/30-linux/run_onchange_after_chsh-zsh.sh.tmpl]=ddd39341d7838275d2904f46b3a42067c5b9771a8013139eff1051d96e11fcce
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-10-files.sh.tmpl]=de15c7411db35e10f4efb7d9e7d86a9d9528fc0705373ae5afb03efbabcec017
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-20-host.sh.tmpl]=70a1d313716912bb41e3250248944a346ca9e1dc628ff1d3c1625c5f0313af28
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-30-network.sh.tmpl]=dacc42cc1cde77257a658445c618ef2f66a435f6f60baf4fb25dfa68c7864bea
)

for template in "${!baseline_hashes[@]}"; do
  rendered="$scratch/$(basename "${template%.tmpl}")"
  normalized="$rendered.normalized"
  render "$template" "$rendered"
  without_facts "$rendered" "$normalized" "$fixture_root"
  actual=$(sha256sum "$normalized" | cut -d ' ' -f1)
  expected=${baseline_hashes[$template]}
  [[ "$actual" == "$expected" ]] || fail \
    "$template changed outside the generated facts-sh block (expected $expected, got $actual)"
done

# Confirm the permitted generated block contains the two new facts.
chsh_rendered="$scratch/run_onchange_after_chsh-zsh.sh"
grep -Fqx '  FACT_JETSON=0' "$chsh_rendered" \
  || fail 'Fedora facts block does not emit FACT_JETSON=0'
grep -Fqx '  FACT_SHARED_HOST=0' "$chsh_rendered" \
  || fail 'Fedora facts block does not emit FACT_SHARED_HOST=0'

printf '%s\n' 'fedora-fact-block-baseline: Fedora x86_64 differs only in the generated fact block'
