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

assert "agent-browser" in linux_units
assert "agent-browser" in macos_units
assert "docker-credential-secretservice" in linux_units
assert "docker-credential-secretservice" not in macos_units
assert "docker-credential-osxkeychain" in macos_units
assert "docker-credential-osxkeychain" not in linux_units

for u in linux_data["units"] + macos_data["units"]:
    assert len(u["commands"]) > 0
    assert str(u["mode"]) in ["0755", "0700", "493", "448"]
' "$linux_json" "$macos_json"

render_source() {
  local src="$1" os="$2" arch="$3" tmpl="$4" extra="${5:-}"
  printf '%s' "$tmpl" | \
    env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$src" --destination "$scratch/target" \
      --override-data "{\"chezmoi\":{\"os\":\"$os\",\"arch\":\"$arch\"}$extra}" \
      execute-template
}

musl_override=',"renderOverrides":{"muslLinux":true}'

# A full source tree, so producer: build units still resolve their fingerprint
# globs, with .chezmoidata copied so the lock can be mutated in place.
make_lock_fixture() {
  local name="$1"
  local dest="$scratch/lockfixture-$name"
  rm -rf "$dest"
  mkdir -p "$dest"
  local entry
  for entry in "$repo_root"/* "$repo_root"/.[!.]*; do
    [[ -e "$entry" ]] || continue
    ln -s "$entry" "$dest/$(basename -- "$entry")"
  done
  rm -f "$dest/.chezmoidata"
  # -L dereferences: when $repo_root is itself a symlink farm (this helper's own
  # output, when a gate runs from a fixture), a plain `cp -a` copies the SYMLINK,
  # and mutate_lock then writes through it into the repository's real
  # .chezmoidata/releases.json. Observed live. Dereference, then refuse to
  # continue unless the fixture owns a regular file.
  cp -a -L "$repo_root/.chezmoidata" "$dest/"
  [[ -f "$dest/.chezmoidata/releases.json" && ! -L "$dest/.chezmoidata/releases.json" ]] ||
    fail "lock fixture $dest/.chezmoidata/releases.json is not a regular file; refusing to mutate a lock outside the fixture"
  printf '%s\n' "$dest"
}

mutate_lock() {
  local dir="$1" tool="$2" field="$3" value="$4"
  python3 -c '
import json, sys
path, tool, field, value = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
artifacts = data["releases"]["tools"][tool]["artifacts"]
for platform in artifacts:
    artifacts[platform][field] = value
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f)
' "$dir/.chezmoidata/releases.json" "$tool" "$field" "$value"
}

rejects unknown-producer 'producer: external' 'producer: madeUpProducer' 'unknown producer'
rejects unknown-safety 'safetyProfile: native-single-file' 'safetyProfile: unknownProfile' 'unknown safetyProfile'
rejects windows-platform 'platforms: [linux, macos]' 'platforms: [linux, macos, windows]' 'unsupported platform'
rejects duplicate-command 'name: agent-browser' $'name: agent-browser\n        - name: agent-browser' 'duplicate public command'
rejects path-traversal 'name: agent-browser' 'name: ../../bin/evil' 'path traversal'
rejects missing-release-tool 'tool: agent-browser' 'tool: nonExistentTool' 'undeclared release tool'
rejects secret-mode-mismatch 'mode: "0700"' 'mode: "0755"' 'secret unit'
rejects mutable-mismatch 'mutableTree: true' 'mutableTree: false' 'must have mutableTree: true'

# R30 (KTD1) — the external store identity is lock-addressed: <version>-<digest12>.
bumped=$(make_lock_fixture digest-bump)
mutate_lock "$bumped" bun sha256 "$(printf 'a%.0s' $(seq 1 64))"
bumped_json=$(render_source "$bumped" linux amd64 '{{ includeTemplate "command-manifest.tmpl" . }}')

python3 -c '
import json, sys

lock_path, linux_raw, macos_raw, bumped_raw = sys.argv[1:5]

with open(lock_path, "r", encoding="utf-8") as f:
    tools = json.load(f)["releases"]["tools"]

linux_units = {u["id"]: u for u in json.loads(linux_raw)["units"]}
macos_units = {u["id"]: u for u in json.loads(macos_raw)["units"]}
bumped_units = {u["id"]: u for u in json.loads(bumped_raw)["units"]}

def externals(units):
    return {i: u for i, u in units.items() if u["producer"] == "external"}

linux_ext = externals(linux_units)
macos_ext = externals(macos_units)

# Every declared external unit renders without a template error and carries an identity.
all_ext = set(linux_ext) | set(macos_ext)
assert len(all_ext) == 30, f"expected 30 external units across both platforms, got {len(all_ext)}"
for scope in (linux_ext, macos_ext):
    for unit_id, unit in scope.items():
        assert unit["identity"], f"external unit {unit_id} rendered an empty identity"

# A unit whose lock entry carries a sha256 gets version + a 12-hex digest suffix.
bun_sha256 = tools["bun"]["artifacts"]["linux-amd64"]["sha256"]
bun_version = tools["bun"]["version"]
assert linux_ext["bun"]["identity"] == f"{bun_version}-{bun_sha256[:12]}", linux_ext["bun"]["identity"]

# agy records a null sha256 and a populated sha512; the sha512 leg must supply the suffix.
agy_artifact = tools["agy"]["artifacts"]["linux-amd64"]
assert agy_artifact["sha256"] is None
agy_version = tools["agy"]["version"]
agy_sha512 = agy_artifact["sha512"]
expected_agy = f"{agy_version}-{agy_sha512[:12]}"
assert linux_ext["agy"]["identity"] == expected_agy, linux_ext["agy"]["identity"]
assert linux_ext["agy"]["identity"] != agy_version

# The version-only units keep the bare version and do not fail the render.
for unit_id, tool in (("kubectl", "kubectl"), ("kubectl-convert", "kubectl"), ("helm", "helm"), ("glab", "glab")):
    assert "artifacts" not in tools[tool], f"{tool} is no longer version-only; update this case"
    assert linux_ext[unit_id]["identity"] == tools[tool]["version"], linux_ext[unit_id]["identity"]

# Units sharing one lock key share one identity.
assert linux_ext["bun"]["identity"] == linux_ext["bunx"]["identity"]

# Identities stay filesystem-safe: they become a directory name under the store.
for scope in (linux_ext, macos_ext):
    for unit_id, unit in scope.items():
        identity = unit["identity"]
        assert "/" not in identity and identity not in (".", ".."), f"{unit_id}: unsafe identity {identity!r}"

# R30: a re-published asset moves the digest while the version holds, so the identity moves too.
assert bumped_units["bun"]["identity"] != linux_ext["bun"]["identity"]
assert bumped_units["bun"]["identity"] == bun_version + "-" + ("a" * 12), bumped_units["bun"]["identity"]
assert bumped_units["bunx"]["identity"] == bumped_units["bun"]["identity"]
for unit_id, unit in externals(bumped_units).items():
    if unit_id not in ("bun", "bunx"):
        assert unit["identity"] == linux_ext[unit_id]["identity"], unit_id
' "$repo_root/.chezmoidata/releases.json" "$linux_json" "$macos_json" "$bumped_json"

# The external identity names the artifact the host downloads, so a musl host
# keys it on the -musl digest while every tool without a -musl lock key keeps
# its plain-platform digest.
musl_json=$(render_source "$repo_root" linux amd64 '{{ includeTemplate "command-manifest.tmpl" . }}' "$musl_override")
musl_bumped=$(make_lock_fixture musl-digest-bump)
python3 -c '
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["releases"]["tools"]["bun"]["artifacts"]["linux-amd64-musl"]["sha256"] = "b" * 64
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f)
' "$musl_bumped/.chezmoidata/releases.json"
musl_bumped_json=$(render_source "$musl_bumped" linux amd64 '{{ includeTemplate "command-manifest.tmpl" . }}' "$musl_override")

python3 -c '
import json, sys

lock_path, linux_raw, musl_raw, musl_bumped_raw = sys.argv[1:5]

with open(lock_path, "r", encoding="utf-8") as f:
    tools = json.load(f)["releases"]["tools"]

def externals(raw):
    return {u["id"]: u for u in json.loads(raw)["units"] if u["producer"] == "external"}

linux_ext = externals(linux_raw)
musl_ext = externals(musl_raw)
musl_bumped_ext = externals(musl_bumped_raw)

# A musl host resolves the musl artifact digest, not the glibc one.
bun_version = tools["bun"]["version"]
bun_musl_sha = tools["bun"]["artifacts"]["linux-amd64-musl"]["sha256"]
assert musl_ext["bun"]["identity"] == f"{bun_version}-{bun_musl_sha[:12]}", musl_ext["bun"]["identity"]
assert musl_ext["bun"]["identity"] != linux_ext["bun"]["identity"]
assert musl_ext["bun"]["identity"] == musl_ext["bunx"]["identity"]

# Every tool carrying a -musl lock key moves with the host libc.
for unit_id in ("bun", "claude", "mise", "agent-browser"):
    assert musl_ext[unit_id]["identity"] != linux_ext[unit_id]["identity"], unit_id

# R30 on the musl leg: a re-published musl asset moves the identity.
assert musl_bumped_ext["bun"]["identity"] == bun_version + "-" + ("b" * 12), musl_bumped_ext["bun"]["identity"]

# The regression guard: a tool with no -musl lock key falls back to the plain
# platform key and keeps a digest-bearing identity instead of a bare version.
for unit_id, tool in (("gh", "gh"), ("uv", "uv")):
    assert "linux-amd64-musl" not in tools[tool]["artifacts"], f"{tool} now has a -musl key; pick another case"
    identity = musl_ext[unit_id]["identity"]
    assert identity == linux_ext[unit_id]["identity"], identity
    assert identity != tools[tool]["version"], f"{unit_id} regressed to a bare version on musl"
    assert identity.rsplit("-", 1)[-1] == tools[tool]["artifacts"]["linux-amd64"]["sha256"][:12], identity

# Every external still renders a non-empty identity on the musl leg.
for unit_id, unit in musl_ext.items():
    assert unit["identity"], f"external unit {unit_id} rendered an empty identity on musl"

# The version-only units keep the bare version on both legs.
for unit_id, tool in (("kubectl", "kubectl"), ("kubectl-convert", "kubectl"), ("helm", "helm"), ("glab", "glab")):
    for scope in (linux_ext, musl_ext):
        assert scope[unit_id]["identity"] == tools[tool]["version"], scope[unit_id]["identity"]
' "$repo_root/.chezmoidata/releases.json" "$linux_json" "$musl_json" "$musl_bumped_json"

# The accessor change is contained: optional:true rescues a missing artifacts block,
# but a non-optional call against one still fails loudly (R6, no live fallback).
optional_out=$(render_source "$repo_root" linux amd64 '[{{ includeTemplate "release-lock-ref.tmpl" (dict "ctx" . "tool" "kubectl" "field" "sha256" "platform" "auto" "optional" true) }}]')
if [[ "$optional_out" != "[]" ]]; then
  fail "expected optional:true against a version-only lock entry to render empty, got: $optional_out"
fi

strict_out=""
if strict_out=$(render_source "$repo_root" linux amd64 '{{ includeTemplate "release-lock-ref.tmpl" (dict "ctx" . "tool" "kubectl" "field" "sha256" "platform" "auto") }}' 2>&1); then
  fail "expected a non-optional lookup against a missing artifacts block to fail, got: $strict_out"
fi
if [[ "$strict_out" != *'has no artifact for platform "linux-amd64"'* || "$strict_out" != *'no live fallback exists (R6)'* ]]; then
  fail "expected the non-optional lookup to fail with the R6 message, got: $strict_out"
fi

strict_platform_out=""
if strict_platform_out=$(render_source "$repo_root" linux amd64 '{{ includeTemplate "release-lock-ref.tmpl" (dict "ctx" . "tool" "bun" "field" "sha256" "platform" "linux-riscv64") }}' 2>&1); then
  fail "expected a non-optional lookup against a missing platform to fail, got: $strict_platform_out"
fi
if [[ "$strict_platform_out" != *'has no artifact for platform "linux-riscv64"'* ]]; then
  fail "expected the missing-platform lookup to name the platform, got: $strict_platform_out"
fi

printf '%s\n' 'command manifest validation passed'
