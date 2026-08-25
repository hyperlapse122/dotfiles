#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/packages-manifest.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf '[data]\n' >"$scratch/empty.toml"

fail() { printf 'packages manifest: %s\n' "$*" >&2; exit 1; }
render() {
  local root=$1
  PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$root" \
    --override-data '{"chezmoi":{"os":"linux","arch":"amd64","osRelease":{"id":"fedora"}}}' \
    execute-template <"$root/.chezmoiscripts/20-base/fedora/run_onchange_before_base.sh.tmpl"
}
render_ubuntu() {
  local root=$1
  PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$root" \
    --override-data '{"chezmoi":{"os":"linux","arch":"arm64","osRelease":{"id":"ubuntu"}}}' \
    execute-template <"$root/.chezmoiscripts/20-base/fedora/run_onchange_before_base.sh.tmpl"
}
assert_ubuntu_gate_closed() {
  local root=$1 authority="$scratch/ubuntu-authority.json"
  printf '%s' '{{ .packages.authority | toJson }}' |
    PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$root" \
      --override-data '{"chezmoi":{"os":"linux","arch":"arm64","osRelease":{"id":"ubuntu"}}}' \
      execute-template >"$authority"
  node - "$authority" <<'JS'
const fs = require("node:fs");
const authority = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (authority.releaseGates.g1 !== "closed") {
  throw new Error(`expected G1 to be closed, got ${authority.releaseGates.g1}`);
}
if (!authority.capabilities.some(({ ubuntu }) => ubuntu.architectures.arm64 === "unresolved")) {
  throw new Error("expected an unresolved Ubuntu arm64 capability while G1 is closed");
}
JS
}
make_fixture() {
  local root=$1
  mkdir -p "$root/.chezmoiscripts/20-base/fedora"
  cp -a "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" "$root/"
  cp -a "$repo_root/.chezmoiscripts/20-base/fedora/run_onchange_before_base.sh.tmpl" \
    "$root/.chezmoiscripts/20-base/fedora/"
}
mutate() {
  local root=$1 old=$2 new=$3 count=${4:-1}
  node - "$root/.chezmoidata/packages.yaml" "$old" "$new" "$count" <<'JS'
const fs = require("node:fs");
const [path, oldText, newText, rawCount] = process.argv.slice(2);
let text = fs.readFileSync(path, "utf8").replace(/\r\n/g, "\n");
if (!text.includes(oldText)) throw new Error(`fixture text not found: ${JSON.stringify(oldText)}`);
let count = Number(rawCount);
while (count-- > 0) text = text.replace(oldText, newText);
const temporaryPath = `${path}.fixture`;
fs.writeFileSync(temporaryPath, text);
fs.renameSync(temporaryPath, path);
JS
}
rejects() {
  local label=$1 old=$2 new=$3 expected=$4 count=${5:-1}
  local root="$scratch/$label"
  make_fixture "$root"
  mutate "$root" "$old" "$new" "$count"
  if render "$root" >"$scratch/$label.out" 2>"$scratch/$label.err"; then
    fail "$label mutation was accepted"
  fi
  grep -F "$expected" "$scratch/$label.err" >/dev/null || {
    cat "$scratch/$label.err" >&2
    fail "$label did not report $expected"
  }
}
rejects_gate_value() {
  local label=$1 value=$2 expected=$3
  local root="$scratch/$label"
  make_fixture "$root"
  mutate "$root" 'bareMetalPackages: "!virt"' "bareMetalPackages: $value"
  mutate "$root" 'gate: "!virt"' "gate: $value"
  if render "$root" >"$scratch/$label.out" 2>"$scratch/$label.err"; then
    fail "$label mutation was accepted"
  fi
  grep -F "$expected" "$scratch/$label.err" >/dev/null || {
    cat "$scratch/$label.err" >&2
    fail "$label did not report $expected"
  }
}


render "$repo_root" >"$scratch/baseline"
render_ubuntu "$repo_root" >"$scratch/ubuntu-baseline"
assert_ubuntu_gate_closed "$repo_root"
rejects missing-disposition 'fedora: { disposition: managed, owner: dnf, identifier: 1password,' 'fedora: { owner: dnf, identifier: 1password,' 'missing disposition'
rejects_gate_value unknown-fact madeUpFact 'unknown fact'
rejects_gate_value malformed-comparison nvidia.true 'BOOLEAN fact'
rejects duplicate-source '    capabilities:' $'      - name: fedora\n        backend: dnf\n        origin: https://mirrors.fedoraproject.org/metalink\n        trusted: true\n    capabilities:' 'duplicate source'
rejects changed-homebrew-origin 'https://github.com/Homebrew/homebrew-cask.git' 'https://github.com/attacker/homebrew-cask.git' 'canonical origin mismatch'
rejects dnf-origin-mismatch 'https://dl.google.com/linux/chrome/rpm/stable/x86_64' 'https://mirror.invalid/chrome' 'canonical origin mismatch' 2
rejects unsafe-field '        bootstrap: true' $'        bootstrap: true\n        shell: sh' 'unsafe/unknown field'
rejects unsupported-id 'identifier: google-chrome-stable' 'identifier: google chrome;calc' 'unsupported identifier'
rejects untrusted-tap $'        backend: homebrew\n        origin: https://github.com/Homebrew/homebrew-cask.git\n        trusted: true' $'        backend: homebrew\n        origin: https://github.com/Homebrew/homebrew-cask.git\n        trusted: false' 'is not trusted'
rejects unavailable-bootstrap 'fedora: { disposition: managed, owner: dnf, identifier: 1password, source: onePassword, architectures: { amd64: native, arm64: native } }' 'fedora: { disposition: managed, owner: dnf, identifier: 1password, source: onePassword, architectures: { amd64: native, arm64: unresolved } }' 'bootstrap capability onePasswordDesktop unavailable'
rejects resolved-g0 'arm64: unresolved' 'arm64: native' 'G0 is closed but no gate-closing architecture remains unresolved' 3
rejects open-g1-with-unresolved 'g1: closed' 'g1: open' 'G1 is open while ubuntu architectures remain unresolved'
rejects gate-mismatch 'gate: "!virt"' 'gate: nvidia' 'gate mismatch'
rejects checksum-omission '        integrity: checksum
        fedora: { disposition: managed, owner: external, identifier: gh' '        fedora: { disposition: managed, owner: external, identifier: gh' 'omits integrity'

printf '%s\n' 'package manifest validation passed'
