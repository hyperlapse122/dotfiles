#!/usr/bin/env bash
# Prove the standard Fedora x86_64 render stays byte-for-byte at its pre-Jetson
# baseline once two GENERATED blocks are removed: the facts-sh assignment group,
# which new host facts legitimately grow, and the shared-host guard, which the
# three system installers share with Ubuntu. No other rendered control flow may
# drift, and the guard must render INERT here (R22).
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

# Replace the two generated blocks with stable markers: the rendered facts-sh
# assignment group, and the shared-host guard the system installers share.
without_facts() {
  local input=$1 output=$2 source_root=$3
  node - "$input" "$output" "$source_root" <<'NODE'
const fs = require("node:fs");
const [input, output, sourceRoot] = process.argv.slice(2);
const source = fs.readFileSync(input, "utf8");

function cut(text, startMarker, endMarker, label, replacement) {
  const start = text.indexOf(startMarker);
  if (start === -1) return text;
  const end = text.indexOf(endMarker, start);
  if (end === -1) throw new Error(`${label} is unterminated in ${input}`);
  const tail = text.slice(end + endMarker.length);
  return replacement === null
    ? `${text.slice(0, start)}${tail}`
    : `${text.slice(0, start)}${replacement}\n${tail}`;
}

let normalized = cut(
  source,
  "# Host facts — GENERATED from .chezmoidata/facts.yaml via\n",
  "\n}\n",
  "facts-sh block",
  "# <GENERATED FACT BLOCK>",
);
// The guard is excised without residue: the baseline hashes predate it, so any
// marker line here would move them.
normalized = cut(
  normalized,
  "# Skip on a shared host; see .chezmoitemplates/shared-host-guard.sh.tmpl",
  "\nfi\n\n",
  "shared-host guard",
  null,
);
fs.writeFileSync(output, normalized.replaceAll(sourceRoot, "<SOURCE_ROOT>"));
NODE
}

# Pre-Jetson Fedora x86_64 hashes after generated facts are normalized.
declare -A baseline_hashes=(
  [.chezmoiscripts/30-linux/run_onchange_after_chsh-zsh.sh.tmpl]=8a2418531929e8c0e1b4440001a674750fee40b5dde96648626d4833678ca771
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-10-desktop.sh.tmpl]=4fc8372442e23d4e7bd12a82c30272b9e7958a71891d7c98fef50259445c5209
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-12-sudoers.sh.tmpl]=6ceb9ae1bd15a55348024460e13701554a924c4ae961ddf0bd3996882d70c725
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-14-sysctl.sh.tmpl]=2d7541daea733281ee980de9eaabcb6dd1f5d6008ce8d811319be25461bb5f63
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-16-udev.sh.tmpl]=2eadcfc779ac005654a0b97225e741c619fcdcfe36f6e666f1b33a0bf4044c15
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-18-hardware.sh.tmpl]=920ab244dd6b8d4e37dfd422a573f6406b2d0417a9bbfe175a8963a10cece00e
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-20-bluetooth.sh.tmpl]=ab69056617db427f593db835a58424fd211613e6ee5320fb8da3040428d85916
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-22-host.sh.tmpl]=856c095622ae325d2d431d7238e882cf7250f79e15a8c114c6960399482db033
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-24-keyd.sh.tmpl]=0a12895347a0c4c162c05377fd4b268cd22a7a1aad14b1394a9fb7b9db370cd4
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-30-network.sh.tmpl]=d7cd8c48ee94f2b7c2ea8170ecd38bdc385f549334d7ca19accfa07744940f56
)

for template in "${!baseline_hashes[@]}"; do
  rendered="$scratch/$(basename "${template%.tmpl}")"
  normalized="$rendered.normalized"
  render "$template" "$rendered"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$rendered" || fail "$template fails shellcheck"
  fi
  bash -n "$rendered" || fail "$template does not render valid shell"
  without_facts "$rendered" "$normalized" "$fixture_root"
  actual=$(sha256sum "$normalized" | cut -d ' ' -f1)
  expected=${baseline_hashes[$template]}
  [[ "$actual" == "$expected" ]] || fail \
    "$template changed outside the two generated blocks (expected $expected, got $actual)"
done

network_render="$scratch/run_onchange_after_install-system-30-network.sh"
! grep -Eq 'systemctl[[:space:]]+(start|restart|reload)([[:space:]]|$)' "$network_render" \
  || fail 'network render still mutates an affected service'
grep -Fq 'NOTE: This installer defers explicit activation for systemd-resolved, NetworkManager, and tailscaled.' "$network_render" \
  || fail 'network render omits affected service names from the deferred activation notice'
grep -Fq 'Restart affected services manually after apply, or reboot the system.' "$network_render" \
  || fail 'network render omits manual restart-or-reboot guidance'
grep -Fq 'site=networkmanager-not-running' "$network_render" \
  || fail 'network render lost the NetworkManager applicability declaration'
keyd_render="$scratch/run_onchange_after_install-system-24-keyd.sh"
render ".chezmoiscripts/30-linux/run_onchange_after_install-system-24-keyd.sh.tmpl" "$keyd_render"
bash -n "$keyd_render" || fail "run_onchange_after_install-system-24-keyd.sh.tmpl does not render valid shell"

# The login-shell script consumes capabilities.tmpl and facts.tmpl, so it never
# carries a FACT_* block; only these two scripts include facts-sh.tmpl.
facts_consumer="$scratch/run_onchange_after_install-system-10-desktop.sh"
grep -Fqx '  FACT_JETSON=0' "$facts_consumer" \
  || fail 'Fedora facts block does not emit FACT_JETSON=0'
grep -Fqx '  FACT_SHARED_HOST=0' "$facts_consumer" \
  || fail 'Fedora facts block does not emit FACT_SHARED_HOST=0'

for script in install-system-10-desktop install-system-12-sudoers install-system-14-sysctl install-system-16-udev install-system-18-hardware install-system-20-bluetooth install-system-22-host install-system-24-keyd install-system-30-network; do
  rendered="$scratch/run_onchange_after_$script.sh"
  grep -Fq 'if [[ "$FACT_SHARED_HOST" -eq 1 ]]; then' "$rendered" \
    || fail "$script does not render the shared-host guard"
  grep -Fqx '  FACT_SHARED_HOST=0' "$rendered" \
    || fail "$script renders the shared-host guard without an inert fact"
done

printf '%s\n' 'fedora-fact-block-baseline: Fedora x86_64 differs only in the generated blocks, and the shared-host guard is inert'
