#!/usr/bin/env bash
# Prove the standard Fedora x86_64 render stays byte-for-byte at its pre-Jetson
# baseline once three GENERATED blocks are removed: the facts-sh assignment group
# and the fact_gate dispatch arms, both of which new host facts legitimately grow,
# and the shared-host guard, which the three system installers share with Ubuntu. No other rendered control flow may
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
gpuDeviceId: ""
gpuArch: ""
hybridGraphics: false
integratedOnly: false
nvidiaHybridDriver: false
battery: false
fingerprintReader: false
displayManager: ""
displayManagerSddm: false
deepSleep: false
thinkpad: false
jetson: false
vm: false
virt: false
sddmBreeze: false
sddmBreezeRetirable: false
sddmBreezeUsable: false
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
// facts-gate.sh.tmpl renders ONE `case` arm per registry fact into fact_gate(),
// so the dispatch table grows with the registry exactly the way the facts-sh
// assignment group does. It sits inside the hashed region, so without this cut a
// single new fact fails eleven baselines with "changed outside the two generated
// blocks" — pointing at a script nobody touched, and at a block that is in fact
// generated. The marker keeps the `*)` guard arm visible, because THAT arm is
// hand-written control flow this gate is meant to watch.
normalized = cut(
  normalized,
  "    want=1\n  fi\n  case \"$name\" in\n",
  "    *)\n",
  "fact-gate dispatch arms",
  "    want=1\n  fi\n  case \"$name\" in\n# <GENERATED FACT GATE ARMS>\n    *)",
);
fs.writeFileSync(output, normalized.replaceAll(sourceRoot, "<SOURCE_ROOT>"));
NODE
}

# Fedora x86_64 hashes after generated facts are normalized.
#
# REBASELINED when sudo-skip-guard was replaced by sudo-elevation-guard. These
# eleven scripts render a different guard body now — an elevation ladder that
# exits 1 instead of a skip that exited 0 — so the rendered control flow this
# gate watches legitimately moved, once, by design. The elevation guard is
# deliberately NOT added to the normalized-away blocks above: it is exactly the
# kind of shared control flow this baseline exists to watch, and excising it
# would blind the gate to a later change in the ladder.
#
# REBASELINED again for install-system-18-hardware when the hybrid-graphics
# drop-ins were added. That installer's own file array and fingerprint globs are
# hand-written control flow, not a generated block, so a new managed /etc file
# legitimately moves its digest exactly once -- and the gate seeing that move is
# the point: a manifest entry alone installs nothing, so the array is what the
# baseline must keep watching.
#
# REBASELINED again for install-system-16-udev and install-system-18-hardware
# when the Pascal integrated-only policy landed: the udev installer gained the
# manifest override gate lookup, and the hardware installer gained the
# integrated-only blacklist in its file array plus a gated retirement loop.
#
# REBASELINED again for install-system-* when Position-Independent Script
# Rendering (PISR) replaced render-time {{ $sourceDir }} interpolation with
# runtime ${CHEZMOI_SOURCE_DIR:-...} parameter expansion, deliberately
# decoupling rendered script bodies from worktree checkout paths.
#
# SCOPE, precisely: the fixture pins `desktop: none`, so these digests watch the
# ladder's THREE-rung shape only. The askpass rung the kde and gnome shapes add
# is not byte-pinned here; `.ci/test-sudo-elevation-guard.sh` is what covers all
# three renderings.
declare -A baseline_hashes=(
  [.chezmoiscripts/30-linux/run_onchange_after_chsh-zsh.sh.tmpl]=d66169165fe4167fb0baeb515ddaba807e63579a2946ae1e51d4cdcb068afbc4
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-10-desktop.sh.tmpl]=68f3e13aab373fe9f5e45bc2b123a941ef7189421c2f16688a4790b8311fd825
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-12-sudoers.sh.tmpl]=3881be450d9a15ba86727e36ab90b4ce70f825bfa87ded61d81e4dcfc653b120
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-14-sysctl.sh.tmpl]=271eeddc315098df82669acba26ce853caae4c798145227f2c2d08e9fab6880d
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-16-udev.sh.tmpl]=1ce5afd3cb6e807f16ac5384c303554982983687e20756c06b724180a0f6672d
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-18-hardware.sh.tmpl]=f077503984d034c21fb61fc6c275898b4d1a3679750f1d8be72c2f3d1f7a6326
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-20-bluetooth.sh.tmpl]=5548d795181a0e8475ec31448dae0f53e2cd42b8d8c99296b46afe08a4691d40
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-22-host.sh.tmpl]=0d67f918c955ca9df3925434384f6a683349865017a2b9d091dd08aa76c760b0
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-24-keyd.sh.tmpl]=de667a915619a4ca5acdaa9a08af5d7ab1dbf40319c5b09f08232ed289c28fcc
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-26-swap-hibernate.sh.tmpl]=2c5a774474b2c795c7145a73cbb05dab2484aa4a5236c35a6fd4e98e64b9a0a2
  [.chezmoiscripts/30-linux/run_onchange_after_install-system-30-network.sh.tmpl]=dc0b94a8166d05d1fddd55ae9c0e8a929ea8a417651073afe8e7d6e508d308d3
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
  if [[ -n "${BASELINE_REPRINT:-}" ]]; then
    printf '  [%s]=%s\n' "$template" "$actual"
    continue
  fi
  [[ "$actual" == "$expected" ]] || fail \
    "$template changed outside the three generated blocks (expected $expected, got $actual)"
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

for script in install-system-10-desktop install-system-12-sudoers install-system-14-sysctl install-system-16-udev install-system-18-hardware install-system-20-bluetooth install-system-22-host install-system-24-keyd install-system-26-swap-hibernate install-system-30-network; do
  rendered="$scratch/run_onchange_after_$script.sh"
  grep -Fq 'if [[ "$FACT_SHARED_HOST" -eq 1 ]]; then' "$rendered" \
    || fail "$script does not render the shared-host guard"
  grep -Fqx '  FACT_SHARED_HOST=0' "$rendered" \
    || fail "$script renders the shared-host guard without an inert fact"
done

printf '%s\n' 'fedora-fact-block-baseline: Fedora x86_64 differs only in the generated blocks, and the shared-host guard is inert'
