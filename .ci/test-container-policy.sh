#!/usr/bin/env bash
# Prove the container policy has ONE resolution and every entry declares itself.
#
# The gate vocabulary in .chezmoidata/commands.yaml already suppressed a command
# LINK in a container; it did not suppress the externals DOWNLOAD, so the payload
# still landed in the image and only the symlink was withheld. ships-in-container.tmpl
# is the one resolution both surfaces now read, and this gate holds three claims:
# the partial answers correctly, the externals files actually ask it, and every
# entry that could ship has a declared answer.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/container-policy.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'container-policy: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'container-policy: ok - %s\n' "$*"; }

command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is required on PATH'

mkdir -p "$scratch/source" "$scratch/target" "$scratch/bin" "$scratch/home" "$scratch/cache/chezmoi"
cp -a "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" "$scratch/source/"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf 'headless: false\nnvidia: false\nvm: false\nvirt: false\nopAvailable: false\n' \
  >"$scratch/cache/chezmoi/facts.yaml"

# containerFact is a renderOverrides seam so this gate can drive both sides from a
# host; the real fact is a stat of /run/.containerenv, which a test cannot forge.
render() {
  local container=$1 body=$2
  (
    cd -- "$scratch/source"
    PATH="$scratch/bin:$PATH" XDG_CACHE_HOME="$scratch/cache" chezmoi \
      --config "$scratch/empty.toml" \
      --source "$PWD" \
      --destination "$scratch/target" \
      --override-data '{"chezmoi":{"os":"linux","arch":"amd64","username":"fx","osRelease":{"id":"fedora"},"homeDir":"'"$scratch"'/home"},"renderOverrides":{"container":'"$container"'}}' \
      execute-template <<<"$body"
  )
}

ask='{{ includeTemplate "ships-in-container.tmpl" (dict "ctx" . "tool" "%s") }}'

# --- 1. A tool whose unit carries gate: "!container".
# shellcheck disable=SC2059
got=$(render true "$(printf "$ask" flutter)") || fail 'render failed for flutter'
[[ "$got" == 'false' ]] || fail "flutter is gated !container; in a container the partial must answer false, got '$got'"
# shellcheck disable=SC2059
got=$(render false "$(printf "$ask" flutter)") || fail 'render failed for flutter on a host'
[[ "$got" == 'true' ]] || fail "on a host flutter must answer true, got '$got'"
pass 'a !container unit is suppressed in a container and kept on a host'

# --- 2. A tool whose unit carries no gate at all.
# shellcheck disable=SC2059
got=$(render true "$(printf "$ask" claude)") || fail 'render failed for claude'
[[ "$got" == 'true' ]] || fail "claude declares no container gate and must answer true, got '$got'"
pass 'an ungated unit ships in a container'

# --- 3. An unknown tool fails loudly. A typo must not silently mean "ship it".
if render true "$(printf "$ask" definitely-not-a-tool)" >/dev/null 2>&1; then
  fail 'an unknown tool must fail the render, not default to shipping'
fi
pass 'an unknown tool fails the render'

# --- 4. What actually survives a container render of the externals.
# A textual "is there a guard" check would pass on a guard around the wrong entry
# and would miss a companion artifact (bunx, sg, uvx, the buf man page) whose
# primary tool is excluded while it is not. Rendering both sides and comparing the
# section lists is the claim that matters: this IS the image's tool inventory.
cp -a "$repo_root/.chezmoiexternals" "$scratch/source/"

sections_for() {
  local container=$1 f
  for f in "$scratch/source/.chezmoiexternals"/*.toml; do
    render "$container" "$(cat "$f")" ||
      { printf 'render failed: %s\n' "$f" >&2; return 1; }
  done | grep -oE '^\[[a-zA-Z][a-zA-Z0-9_.-]*\]' | tr -d '[]' |
    grep -v '\.checksum$' | sort -u
}

# The worker keep set (R13) as delivered by EXTERNALS. chezmoi and op are in the
# image too but arrive from .install-prerequisites.sh, not from here.
# Everything an agent needs to edit, run, version, and
# provision per-project toolchains -- and nothing else.
want_container=$(printf '%s\n' bun bunx claude codex codex-code-mode-host gh glab mise | sort)

got_container=$(sections_for true) || fail 'container render of externals failed'
if [[ "$got_container" != "$want_container" ]]; then
  fail "the container render's externals set is not the keep set.
  unexpected: $(comm -23 <(printf '%s\n' "$got_container") <(printf '%s\n' "$want_container") | tr '\n' ' ')
  missing:    $(comm -13 <(printf '%s\n' "$got_container") <(printf '%s\n' "$want_container") | tr '\n' ' ')"
fi
pass 'the container render installs exactly the keep set'

got_host=$(sections_for false) || fail 'host render of externals failed'
for keep in $want_container; do
  grep -qx "$keep" <<<"$got_host" || fail "$keep must also be present on a host, and is not"
done
host_only=$(comm -13 <(printf '%s\n' "$want_container") <(printf '%s\n' "$got_host") | wc -l)
((host_only > 0)) || fail 'the host render must install MORE than the container render; host behaviour was not preserved'
pass "the host render is unchanged and installs $host_only more entries"

# --- 5. Every declared container policy is a value the readers accept.
bad=$(grep -n 'container:' "$repo_root/.chezmoidata/agents.yaml" |
  grep -vE 'container: (keep|skip)$' || true)
[[ -z "$bad" ]] || fail "agents.yaml has container values outside keep|skip: $bad"
pass 'every declared container policy in agents.yaml is keep or skip'

printf 'container-policy: OK\n'
