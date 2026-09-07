#!/usr/bin/env bash
# Prove that op:// references resolve only when opAvailable says they may.
#
# resolve-op-refs-json.tmpl is the single place this repository turns an op://
# reference into a secret value, and five templates reach it. An image build runs
# with opAvailable false and must emit the REFERENCE; the pod's apply runs with it
# true and must emit the VALUE. The two checks below are different in kind and both
# are needed: the first proves the partial's own behaviour, the second proves every
# consumer actually asks for it -- a consumer that forgets gets the fail-closed
# default, which is a visible unresolved reference rather than a baked credential,
# but it is still a defect and this is what names it.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/op-ref-gating.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'op-ref-gating: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'op-ref-gating: ok - %s\n' "$*"; }

command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is required on PATH'

mkdir -p "$scratch/source" "$scratch/target" "$scratch/bin" "$scratch/home"
cp -a "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" "$scratch/source/"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"

render() {
  (
    cd -- "$scratch/source"
    PATH="$scratch/bin:$PATH" chezmoi \
      --config "$scratch/empty.toml" \
      --source "$PWD" \
      --destination "$scratch/target" \
      --override-data '{"chezmoi":{"os":"linux","arch":"amd64","username":"fx","osRelease":{"id":"fedora"},"homeDir":"'"$scratch"'/home"}}' \
      execute-template
  )
}

# --- 1. The partial resolves only when asked, and recurses with the answer.
nested='{{ includeTemplate "resolve-op-refs-json.tmpl" (dict "value" (dict "outer" (dict "key" "op://vault/item/field")) "resolveSecrets" %s) }}'

# shellcheck disable=SC2059  # the format string is the fixture
out=$(printf "$nested" true | render) || fail 'render failed with resolveSecrets true'
[[ "$out" == *dummy-secret* ]] || fail "resolveSecrets true must resolve the reference, got: $out"
[[ "$out" != *'op://'* ]] || fail "resolveSecrets true must not leave the reference behind, got: $out"
pass 'resolveSecrets true resolves a nested reference'

# shellcheck disable=SC2059
out=$(printf "$nested" false | render) || fail 'render failed with resolveSecrets false'
[[ "$out" == *'op://vault/item/field'* ]] || fail "resolveSecrets false must emit the reference, got: $out"
[[ "$out" != *dummy-secret* ]] || fail "resolveSecrets false must not resolve, got: $out"
pass 'resolveSecrets false emits the reference unresolved, through recursion'

# --- 2. The default is fail-closed. A consumer that forgets the argument gets a
# visible unresolved reference; the alternative default bakes a credential.
out=$(printf '{{ includeTemplate "resolve-op-refs-json.tmpl" (dict "value" "op://vault/item/field") }}' | render) \
  || fail 'render failed with resolveSecrets absent'
[[ "$out" == *'op://vault/item/field'* ]] || fail "an absent resolveSecrets must not resolve, got: $out"
[[ "$out" != *dummy-secret* ]] || fail "an absent resolveSecrets must not resolve, got: $out"
pass 'the absent-argument default is fail-closed'

# --- 3. Every consumer passes the argument.
# grep, not a render: this is a completeness claim about the source tree, and a
# render can only ever exercise the consumers this test happens to know about.
mapfile -t consumers < <(
  grep -rln 'includeTemplate "resolve-op-refs-json.tmpl"' \
    --include='*.tmpl' "$repo_root" |
    grep -v '/\.chezmoitemplates/resolve-op-refs-json\.tmpl$' | sort
)
((${#consumers[@]} > 0)) || fail 'no consumers found; the grep pattern has drifted'
for consumer in "${consumers[@]}"; do
  rel=${consumer#"$repo_root/"}
  grep -q '"resolveSecrets"' "$consumer" \
    || fail "$rel calls resolve-op-refs-json.tmpl without passing resolveSecrets"
done
pass "all ${#consumers[@]} consumers pass resolveSecrets"

printf 'op-ref-gating: OK\n'
