#!/usr/bin/env bash
# Prove the hook fact cache is parsed PER LINE.
#
# The cache is written by write_facts_cache in .install-prerequisites.sh and read
# by .chezmoitemplates/facts.tmpl. It used to be shape-checked as a whole file, so
# a single unparseable line voided EVERY fact — and two hook facts (`headless`,
# `virt`) carry an inverted absentDefault of true, which makes that void skip the
# entire /etc install set and the desktop provisioning on an ordinary desktop,
# with a successful exit code. Per-line parsing bounds that blast radius to the
# one fact whose line is bad, and the dropped name is reported so the writer
# defect cannot hide.
#
# This test renders the REAL facts.tmpl against crafted caches. It asserts only
# on hook facts; template-layer facts legitimately vary with the runner's host.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/fact-cache-parsing.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() {
  printf 'fact-cache-parsing: FAIL: %s\n' "$*" >&2
  exit 1
}

command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is required on PATH'

mkdir -p "$scratch/source" "$scratch/target" "$scratch/cache/chezmoi" "$scratch/bin" "$scratch/home"
cp -a "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" "$scratch/source/"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"

cache_file="$scratch/cache/chezmoi/facts.yaml"

# Inject one string-valued hook fact into the FIXTURE registry only. The registry
# in the repository gains its own string facts elsewhere; this keeps the parsing
# mechanism provable on its own.
cat >>"$scratch/source/.chezmoidata/facts.yaml" <<'FIXTURE'
  ciFixtureString:
    type: string
    probe: hook
    absentDefault: ""
    source: Test fixture for per-line cache parsing. Not a real host fact.
    gates: nothing.
    whenFalse: Empty, which is the skip value for every string fact.
FIXTURE

render() {
  (
    cd -- "$scratch/source"
    PATH="$scratch/bin:$PATH" XDG_CACHE_HOME="$scratch/cache" chezmoi \
      --config "$scratch/empty.toml" \
      --source "$PWD" \
      --destination "$scratch/target" \
      --override-data '{"chezmoi":{"os":"linux","arch":"amd64","username":"fx","osRelease":{"id":"fedora"},"homeDir":"'"$scratch"'/home"}}' \
      execute-template <<<'{{ includeTemplate "facts.tmpl" . }}'
  )
}

# The map is emitted with toYaml, which quotes a string only when it would
# otherwise parse as something else — the empty string, and a numeric-looking id
# such as `2704`. Consumers read the map back through fromYaml and see a plain
# string either way, so the quoting is normalized here rather than asserted on.
assert_fact() {
  local rendered=$1 name=$2 want=$3 context=$4 got
  got=$(printf '%s\n' "$rendered" | sed -n "s/^${name}: //p")
  got=${got#\"}
  got=${got%\"}
  [[ "$got" == "$want" ]] ||
    fail "$context: expected ${name}=${want:-<empty>}, rendered ${name}=${got:-<empty>}"
}

# --- 1. A well-formed cache is read, and every hook fact takes its cached value.
printf 'nvidia: true\nvm: false\nvirt: false\nheadless: false\n' >"$cache_file"
out=$(render) || fail 'render failed on a well-formed cache'
assert_fact "$out" nvidia true 'well-formed cache'
assert_fact "$out" headless false 'well-formed cache'
assert_fact "$out" virt false 'well-formed cache'

# --- 2. An unparseable line drops ONLY itself. The inverted-default facts must
#        keep their cached values, because that is the blast radius this bounds.
printf 'nvidia: true\nvm: false\nvirt: false\nheadless: false\nthis line has no colon\n' >"$cache_file"
out=$(render) || fail 'render failed on a cache with one unparseable line'
assert_fact "$out" nvidia true 'one unparseable line'
assert_fact "$out" headless false 'one unparseable line'
assert_fact "$out" virt false 'one unparseable line'

# --- 3. A malformed line for a REAL fact defaults that fact alone.
printf 'nvidia: yes-please\nvm: false\nvirt: false\nheadless: false\n' >"$cache_file"
out=$(render) || fail 'render failed on a cache with one malformed boolean'
assert_fact "$out" nvidia false 'malformed boolean defaults its own fact'
assert_fact "$out" headless false 'malformed boolean leaves its neighbours alone'

# --- 4. A string-valued hook fact round-trips through the cache.
printf 'nvidia: true\nvm: false\nvirt: false\nheadless: false\nciFixtureString: "pascal"\n' >"$cache_file"
out=$(render) || fail 'render failed on a cache carrying a string fact'
assert_fact "$out" ciFixtureString pascal 'string hook fact'
assert_fact "$out" nvidia true 'string hook fact leaves booleans alone'

# --- 5. No cache at all: every hook fact takes its declared absentDefault, and
#        the two inverted ones resolve true so their guards skip.
rm -f "$cache_file"
out=$(render) || fail 'render failed with no cache present'
assert_fact "$out" nvidia false 'absent cache'
assert_fact "$out" vm false 'absent cache'
assert_fact "$out" headless true 'absent cache'
assert_fact "$out" virt true 'absent cache'
assert_fact "$out" ciFixtureString '' 'absent cache'

# --- 6. A comments-only cache is not mistaken for facts.
printf '# generated\n# do not edit\n' >"$cache_file"
out=$(render) || fail 'render failed on a comments-only cache'
assert_fact "$out" headless true 'comments-only cache'

# --- 7. gpuArch maps a listed device id through nvidia.deviceArchitectures.
listed_id=$(sed -n 's/^ *"\([0-9a-f]\{4\}\)": *[a-z].*/\1/p' \
  "$repo_root/.chezmoidata/nvidia.yaml" | head -1)
[[ -n "$listed_id" ]] || fail 'no device id is listed in .chezmoidata/nvidia.yaml'
listed_arch=$(sed -n "s/^ *\"${listed_id}\": *\([a-z][a-z0-9]*\).*/\1/p" \
  "$repo_root/.chezmoidata/nvidia.yaml" | head -1)
printf 'nvidia: true\ngpuDeviceId: "%s"\nvm: false\nvirt: false\nheadless: false\n' \
  "$listed_id" >"$cache_file"
out=$(render) || fail 'render failed on a listed device id'
assert_fact "$out" gpuArch "$listed_arch" 'listed device id'

# --- 8. An UNLISTED id resolves gpuArch empty but PRESERVES the id, which the
#        installer needs in order to name the device in its declared skip. An
#        all-digit id is the regression this guards: written unquoted it parses
#        out of YAML as a number, fails the string type check, and the identity
#        is lost exactly when it is needed.
printf 'nvidia: true\ngpuDeviceId: "2704"\nvm: false\nvirt: false\nheadless: false\n' >"$cache_file"
out=$(render) || fail 'render failed on an unlisted all-digit device id'
assert_fact "$out" gpuArch '' 'unlisted all-digit id resolves no architecture'
assert_fact "$out" gpuDeviceId 2704 'unlisted all-digit id is preserved'

# --- 9a. displayManagerSddm is the negatable companion to the displayManager
#         string, because the gate grammar rejects !displayManager.sddm and the
#         SDDM greeter drop-in's retirement needs exactly that negation.
printf 'nvidia: false\ngpuDeviceId: ""\ndisplayManager: "sddm"\nvm: false\nvirt: false\nheadless: false\n' >"$cache_file"
out=$(render) || fail 'render failed on an SDDM host'
assert_fact "$out" displayManager sddm 'SDDM host'
assert_fact "$out" displayManagerSddm true 'SDDM host'

printf 'nvidia: false\ngpuDeviceId: ""\ndisplayManager: "plasmalogin"\nvm: false\nvirt: false\nheadless: false\n' >"$cache_file"
out=$(render) || fail 'render failed on a non-SDDM host'
assert_fact "$out" displayManager plasmalogin 'non-SDDM host'
assert_fact "$out" displayManagerSddm false 'non-SDDM host'

printf 'nvidia: false\ngpuDeviceId: ""\ndisplayManager: ""\nvm: false\nvirt: false\nheadless: false\n' >"$cache_file"
out=$(render) || fail 'render failed with no display manager'
assert_fact "$out" displayManagerSddm false 'no display manager'

# --- 9. No NVIDIA display device: both facts empty, every gated path skips.
printf 'nvidia: false\ngpuDeviceId: ""\nvm: false\nvirt: false\nheadless: false\n' >"$cache_file"
out=$(render) || fail 'render failed with no NVIDIA device'
assert_fact "$out" gpuArch '' 'no NVIDIA device'
assert_fact "$out" gpuDeviceId '' 'no NVIDIA device'

printf 'fact-cache-parsing: OK\n'
