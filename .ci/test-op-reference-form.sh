#!/usr/bin/env bash
set -euo pipefail

# Every secret this repository consumes used to live in the shared `Private`
# vault. Once worker pods resolve secrets through 1Password Connect, the
# token's vault scope is the only boundary left, so the secrets were split
# into two purpose-scoped vaults and every reference now addresses its vault
# by UUID. Neither half of that holds by itself:
#
# TWO CHECKS.
#   1. Every `op://` reference carries a 26-character lowercase-alphanumeric
#      vault segment. A leftover name-based segment, a leftover old-vault
#      UUID, and any newly introduced name-based reference all fail the same
#      way. The rule is uniform across the repository --
#      prose, comments and historical plans included -- which is what lets this
#      check run with no exclusion list to keep in sync.
#   2. No target the container path renders reaches the host-only vault. A
#      worker Connect token is scoped to the agents vault alone, so a
#      container-rendered target that resolves a host-vault reference would ask
#      for a vault it cannot read and fail at apply time, far from this file.
#
# Check 2 is separate from check 1 because they fail for different reasons: a
# check-1 violation is a malformed reference, while a check-2 violation is a
# well-formed reference in the wrong place. Both read the same reference set.
#
# Placeholders are not references. Elided and angle-bracket forms appear in
# prose and in this repository's own planning documents; none has a real vault
# segment, so check 1 skips any segment containing `<` or `>` and never matches
# a form with no segment-then-slash shape at all.
#
# The scheme is assembled into `scheme` rather than written literally, so this
# gate does not report its own source as a violation and needs no exclusion for
# itself -- which is the whole point of check 1 having no exclusion list.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$repo_root"

HOST_VAULT=njbkpy6emfxkbl7n6zmwmz7jfu
scheme='op:''//'

fail() {
  printf 'test-op-reference-form: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'test-op-reference-form: ok - %s\n' "$*"
}

# --- Check 1: every reference names its vault by UUID -----------------------

violations=$(
  grep -rnoE "${scheme}"'[^/"'"'"' }`)]+/' --exclude-dir=.git . \
    | grep -vE "${scheme}[a-z0-9]{26}/" \
    | grep -v '<' \
    || true
)

if [[ -n $violations ]]; then
  printf 'test-op-reference-form: references must name their vault by UUID:\n' >&2
  printf '%s\n' "$violations" >&2
  fail 'at least one op:// reference does not carry a 26-character vault UUID'
fi

pass 'every reference carries a vault UUID'

# --- Check 2: nothing a container renders reaches the host vault ------------

# The container-rendered target set is whatever `.chezmoiignore` does NOT
# exclude when the `container` fact is true. Rather than maintain a second
# hand-written list that would drift, read the guard block itself and treat the
# sources behind those targets as out of scope for this check.
container_block=$(
  awk '/^{{- if \$f\.container \}\}/{inblock=1; next} /^{{- end \}\}/{inblock=0} inblock' \
    .chezmoiignore | grep -vE '^\s*(#|\{\{|$)' || true
)

[[ -n $container_block ]] || fail 'could not read the container guard block from .chezmoiignore; check 2 cannot compute its target set and must not pass vacuously'

# Sources that resolve a host-vault reference at RENDER time. `infra` joins
# `docs` as an exclusion for the same reason: `.chezmoiignore` excludes it
# wholesale, so chezmoi renders nothing there and its `op://` references are
# seeding instructions for a human running `op inject`, not template inputs.
# Scanning it would ask this check to prove a container guard for a target that
# does not exist.
host_refs=$(grep -rlE "${scheme}$HOST_VAULT/" --include='*.tmpl' --include='*.yaml' \
  --exclude-dir=.git --exclude-dir=docs --exclude-dir=infra . || true)

[[ -n $host_refs ]] || fail 'no source references the host vault; the reference map has drifted from this gate'

# Map each host-vault-referencing source to the target it renders, then require
# the container guard to exclude that target.
declare -A target_of=(
  ['dot_local/share/accounts/providers/google.provider.tmpl']='.local/share/accounts/providers/google.provider'
  ['.chezmoidata/networking.yaml']='.local/share/chezmoi-command-sources/import-wifi-1password'
  ['.chezmoidata/kde.yaml']='.local/share/accounts/providers/google.provider'
  ['.chezmoiscripts/10-auth/run_once_after_auth-tailscale.sh.tmpl']='.chezmoiscripts/10-auth/*.sh'
  ['.chezmoiscripts/10-auth/run_onchange_after_auth-tokscale.sh.tmpl']='.chezmoiscripts/10-auth/*.sh'
  ['.chezmoiscripts/30-linux/run_onchange_after_config-wakatime-keyring.sh.tmpl']='.chezmoiscripts/30-linux/*.sh'
  ['.chezmoiscripts/80-keys/run_once_before_import-gpg-key.sh.tmpl']='.chezmoiscripts/80-keys/*.sh'
)

unguarded=()
while IFS= read -r src; do
  src=${src#./}
  target=${target_of[$src]-}
  if [[ -z $target ]]; then
    unguarded+=("$src (no known render target -- add it to this gate's map)")
    continue
  fi
  grep -Fxq -- "$target" <<<"$container_block" \
    || unguarded+=("$src -> $target")
done <<<"$host_refs"

if (( ${#unguarded[@]} > 0 )); then
  printf 'test-op-reference-form: these reach the host vault but render in a container:\n' >&2
  printf '  %s\n' "${unguarded[@]}" >&2
  fail 'a worker Connect token could not read the vault these targets need'
fi

pass 'no container-rendered target reaches the host vault'
