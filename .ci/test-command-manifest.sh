#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/command-manifest.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/target"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"

fail() { printf 'command manifest: %s\n' "$*" >&2; exit 1; }

render() {
  local os="${1:-linux}"
  local arch="amd64"
  if [[ "$os" == "macos" ]]; then
    os="darwin"
    arch="arm64"
  fi
  printf '%s' '{{ includeTemplate "command-manifest.tmpl" . }}' | \
    env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" --destination "$scratch/target" \
      --override-data "{\"chezmoi\":{\"os\":\"$os\",\"arch\":\"$arch\"}}" \
      execute-template
}

make_fixture() {
  local name="$1"
  local dest="$scratch/fixture-$name"
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -a "$repo_root/.chezmoidata" "$dest/"
  cp -a "$repo_root/.chezmoitemplates" "$dest/"
  printf '%s\n' "$dest"
}

mutate() {
  local dir="$1" pattern="$2" replacement="$3"
  local target="$dir/.chezmoidata/commands.yaml"
  python3 -c '
import sys
path, pattern, repl = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
if pattern not in content:
    sys.exit(f"pattern {pattern!r} not found in {path}")
new_content = content.replace(pattern, repl, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(new_content)
' "$target" "$pattern" "$replacement"
}

rejects() {
  local name="$1" pattern="$2" replacement="$3" expected="$4"
  local fix
  fix=$(make_fixture "$name")
  mutate "$fix" "$pattern" "$replacement"
  local output=""
  if output=$(printf '%s' '{{ includeTemplate "command-manifest.tmpl" . }}' | env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$fix" --destination "$scratch/target" --override-data '{"chezmoi":{"os":"linux","arch":"amd64"}}' execute-template 2>&1); then
    fail "expected rejection for $name, but render succeeded: $output"
  fi
  if [[ "$output" != *"$expected"* ]]; then
    fail "expected rejection for $name to contain '$expected', got: $output"
  fi
}

linux_json=$(render linux)
macos_json=$(render macos)

python3 -c '
import json, sys

linux_data = json.loads(sys.argv[1])
macos_data = json.loads(sys.argv[2])

assert linux_data["schemaVersion"] == "command-manifest/v1"
assert macos_data["schemaVersion"] == "command-manifest/v1"

linux_units = {u["id"]: u for u in linux_data["units"]}
macos_units = {u["id"]: u for u in macos_data["units"]}

assert "omp" in linux_units
assert "omp" in macos_units
assert "docker-credential-secretservice" in linux_units
assert "docker-credential-secretservice" not in macos_units
assert "docker-credential-osxkeychain" in macos_units
assert "docker-credential-osxkeychain" not in linux_units

for u in linux_data["units"] + macos_data["units"]:
    assert len(u["commands"]) > 0
    assert str(u["mode"]) in ["0755", "0700", "493", "448"]
' "$linux_json" "$macos_json"

rejects unknown-producer 'producer: external' 'producer: madeUpProducer' 'unknown producer'
rejects unknown-safety 'safetyProfile: native-single-file' 'safetyProfile: unknownProfile' 'unknown safetyProfile'
rejects windows-platform 'platforms: [linux, macos]' 'platforms: [linux, macos, windows]' 'unsupported platform'
rejects duplicate-command 'name: agent-browser' $'name: agent-browser\n        - name: omp' 'duplicate public command'
rejects path-traversal 'name: agent-browser' 'name: ../../bin/evil' 'path traversal'
rejects missing-release-tool 'tool: agent-browser' 'tool: nonExistentTool' 'undeclared release tool'
rejects secret-mode-mismatch 'mode: "0700"' 'mode: "0755"' 'secret unit'
rejects mutable-mismatch 'mutableTree: true' 'mutableTree: false' 'must have mutableTree: true'

printf '%s\n' 'command manifest validation passed'
