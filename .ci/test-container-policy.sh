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

ships_in_container() {
  render "$1" '{{ includeTemplate "ships-in-container.tmpl" (dict "ctx" . "tool" "'"$2"'") }}'
}

# --- 1. A tool whose unit carries gate: "!container".
got=$(ships_in_container true flutter) || fail 'render failed for flutter'
[[ "$got" == 'false' ]] || fail "flutter is gated !container; in a container the partial must answer false, got '$got'"
got=$(ships_in_container false flutter) || fail 'render failed for flutter on a host'
[[ "$got" == 'true' ]] || fail "on a host flutter must answer true, got '$got'"
pass 'a !container unit is suppressed in a container and kept on a host'

# --- 2. A tool whose unit carries no gate at all.
got=$(ships_in_container true claude) || fail 'render failed for claude'
[[ "$got" == 'true' ]] || fail "claude declares no container gate and must answer true, got '$got'"
pass 'an ungated unit ships in a container'

# --- 3. An unknown tool fails loudly. A typo must not silently mean "ship it".
if ships_in_container true definitely-not-a-tool >/dev/null 2>&1; then
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

# --- 5b. Every external command the container manifest declares must have a
# payload. This is the coupling the other checks miss, and the one that breaks a
# BUILD rather than merely bloating an image: gating an externals entry stops the
# download but does not retire the command unit expecting it, and a companion
# unit (sg from ast-grep, uvx from uv, the two protoc plugins from buf) has its
# own unit nobody thinks to gate. command-reconcile then fails at image-build
# time looking for a staging path that was never created.
#
# Rendered with the ROOT context, not a dict: command-manifest.tmpl reads
# .commands off `.`. A manifest that will not render is a hard failure here, never
# a skip -- a silently-skipped version of this check is what let the gap reach a
# real build.
command -v jq >/dev/null 2>&1 || fail 'jq is required on PATH'
# Rendered against the REAL tree, not the fixture: units carry fingerprintGlobs
# over paths like packages/package.json, and fingerprint.tmpl fails hard on a glob
# that matches nothing. Copying an ever-growing file list into the fixture would
# be a second inventory to keep in step; the manifest is about the whole
# repository anyway.
manifest=$(
  cd -- "$repo_root"
  PATH="$scratch/bin:$PATH" XDG_CACHE_HOME="$scratch/cache" chezmoi \
    --config "$scratch/empty.toml" --source "$repo_root" --destination "$scratch/target" \
    --override-data '{"chezmoi":{"os":"linux","arch":"amd64","username":"fx","osRelease":{"id":"fedora"},"homeDir":"'"$scratch"'/home"},"renderOverrides":{"container":true}}' \
    execute-template <<<'{{ includeTemplate "command-manifest.tmpl" . }}'
) || fail 'the container command manifest does not render'
[[ -n "$manifest" ]] || fail 'the container command manifest rendered empty'

have=$(sections_for true)
orphans=""
while IFS=$'\t' read -r unit staging; do
  [[ -n "$unit" ]] || continue
  grep -qx "${staging##*/}" <<<"$have" || orphans+="
  $unit (needs the externals entry ${staging##*/})"
done < <(jq -r '.units[] | select(.producer == "external") | "\(.id)\t\(.stagingPath)"' <<<"$manifest")

[[ -z "$orphans" ]] || fail "these commands survive a container render but their payload does not:$orphans
  Gate the unit !container too, or stop gating its externals entry."
pass 'every external command the container manifest declares has a payload'

# --- 6. The container predicate exists twice, and both copies must agree.
# facts.tmpl owns it for everything that renders from the source state, but
# .chezmoi.toml.tmpl renders BEFORE the source state, so it cannot read the fact
# and carries its own copy. Two copies of a predicate is exactly the shape that
# drifts silently: the config would keep pointing sourceDir at a host path in an
# image whose every other decision had already switched.
predicate_of() {
  grep -A4 'stat "/run/.containerenv"' "$1" |
    tr -d ' \t' | grep -oE 'stat"[^"]+"' | sort
}
facts_pred=$(predicate_of "$repo_root/.chezmoitemplates/facts.tmpl")
config_pred=$(predicate_of "$repo_root/.chezmoi.toml.tmpl")
[[ -n "$facts_pred" ]] || fail 'the container predicate was not found in facts.tmpl'
[[ "$facts_pred" == "$config_pred" ]] || fail "the container predicate in .chezmoi.toml.tmpl has drifted from facts.tmpl.
  facts.tmpl:        $(tr '\n' ' ' <<<"$facts_pred")
  .chezmoi.toml.tmpl: $(tr '\n' ' ' <<<"$config_pred")"
pass 'both copies of the container predicate stat the same markers'

printf 'container-policy: OK\n'
