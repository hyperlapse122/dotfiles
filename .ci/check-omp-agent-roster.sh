#!/usr/bin/env bash
set -euo pipefail

# The declared task.agentModelOverrides map is EXHAUSTIVE over omp's bundled
# agents, not a diff against their frontmatter. That is what makes the mapping
# immune to a release retuning a `model:` field — but exhaustiveness is a claim
# no other layer keeps. An agent omp gains lands on its own frontmatter or the
# session model, indistinguishable from a correct placement; an agent omp drops
# leaves a dead entry nothing reports. Both directions are drift, so this
# compares the two sets and fails on either difference.
#
# It lives in CI rather than the provisioner because the roster is a property of
# the omp RELEASE this repository pins, checked once before merge, not a
# per-host runtime fact. At apply time the same mismatch would abort every
# declared setting on every host the moment the release lock moves.
#
# It needs a real omp binary, so it cannot live in test-omp-agent-reconcile.sh,
# which stubs omp entirely.

usage='usage: check-omp-agent-roster.sh SETTINGS_SH'
settings_script=${1:?$usage}

command -v omp >/dev/null || {
  printf 'check-omp-agent-roster: omp is not on PATH; this check requires the locked binary\n' >&2
  exit 1
}

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/omp-agent-roster
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT

# The rendered provisioner embeds the declared settings as a heredoc; read the
# map from there rather than the source data, so this checks what actually ships.
declared_json="$scratch/declared.json"
awk '/^cat >"\$declared"/{flag=1;next}/^JSON$/{flag=0}flag' "$settings_script" >"$declared_json"
jq -e 'type == "object" and (keys | length) > 0' "$declared_json" >/dev/null || {
  printf 'check-omp-agent-roster: no declared settings found in %s\n' "$settings_script" >&2
  exit 1
}
jq -r '."task.agentModelOverrides" // {} | keys[]' "$declared_json" | sort -u >"$scratch/declared.txt"

# A bare HOME keeps a developer's own agent directory from leaking project or
# user agents into the roster; only the bundled set may answer here.
env -i HOME="$scratch/home" PATH="$PATH" omp agents unpack --dir "$scratch/agents" --json >/dev/null
find "$scratch/agents" -maxdepth 1 -name '*.md' -exec basename {} .md \; | sort -u >"$scratch/bundled.txt"

bundled_count=$(wc -l <"$scratch/bundled.txt")
[[ $bundled_count -gt 0 ]] || {
  printf 'check-omp-agent-roster: omp reported no bundled agents; the comparison would pass vacuously\n' >&2
  exit 1
}

status=0
while IFS= read -r name; do
  [[ -n $name ]] || continue
  printf 'check-omp-agent-roster: omp bundles %s, which task.agentModelOverrides does not declare; it would resolve through its own frontmatter or the session model with no signal\n' "$name" >&2
  status=1
done < <(comm -23 "$scratch/bundled.txt" "$scratch/declared.txt")
while IFS= read -r name; do
  [[ -n $name ]] || continue
  printf 'check-omp-agent-roster: task.agentModelOverrides declares %s, which omp no longer bundles; the entry is dead data\n' "$name" >&2
  status=1
done < <(comm -13 "$scratch/bundled.txt" "$scratch/declared.txt")

[[ $status -eq 0 ]] || {
  printf 'check-omp-agent-roster: declared %d, bundled %d; see the differences above\n' \
    "$(wc -l <"$scratch/declared.txt")" "$bundled_count" >&2
  exit 1
}

printf 'check-omp-agent-roster: %d bundled agents all mapped\n' "$bundled_count"
