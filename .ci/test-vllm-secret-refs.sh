#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
checker="$repo_root/.ci/check-vllm-secret-refs.sh"
scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p -- "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/vllm-secret-refs-gates.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() {
  printf 'vllm-secret-refs gates: FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'vllm-secret-refs gates: ok - %s\n' "$*"
}

seed() {
  local dest=$1
  mkdir -p "$dest/.chezmoidata"
  cp "$repo_root"/.chezmoidata/*.yaml "$dest/.chezmoidata/"
}

baseline="$scratch/baseline"
seed "$baseline"

"$checker" "$baseline" >/dev/null || fail 'rejected clean baseline fixture'
"$checker" "$repo_root" >/dev/null || fail 'rejected real repository data'
pass 'clean baseline and repository pass'

c1="$scratch/c1"; seed "$c1"
sed -i 's|apiKeyRef:.*|apiKeyRef: "sk-literal-secret-12345"|' "$c1/.chezmoidata/vllm.yaml"
out1=$("$checker" "$c1" 2>&1) && fail 'did not reject literal apiKeyRef in vllm.yaml'
grep -qF 'apiKeyRef must be an op:// reference' <<<"$out1" || fail 'rejection did not name apiKeyRef op:// requirement'
pass 'mutant 1: literal apiKeyRef in vllm.yaml rejected'

c2="$scratch/c2"; seed "$c2"
sed -i 's|apiKeyRef:.*|"apiKeyRef": "literal-secret-val"|' "$c2/.chezmoidata/vllm.yaml"
out2=$("$checker" "$c2" 2>&1) && fail 'did not reject double-quoted literal apiKeyRef in vllm.yaml'
grep -qF 'apiKeyRef must be an op:// reference' <<<"$out2" || fail 'rejection did not name quoted apiKeyRef requirement'
pass 'mutant 2: double-quoted literal apiKeyRef rejected'

c3="$scratch/c3"; seed "$c3"
sed -i "s|apiKeyRef:.*|'apiKeyRef': 'literal-secret-val'|" "$c3/.chezmoidata/vllm.yaml"
out3=$("$checker" "$c3" 2>&1) && fail 'did not reject single-quoted literal apiKeyRef in vllm.yaml'
grep -qF 'apiKeyRef must be an op:// reference' <<<"$out3" || fail 'rejection did not name single-quoted apiKeyRef requirement'
pass 'mutant 3: single-quoted literal apiKeyRef rejected'

c4="$scratch/c4"; seed "$c4"
sed -i '/apiKeyRef:/d' "$c4/.chezmoidata/vllm.yaml"
out4=$("$checker" "$c4" 2>&1) && fail 'did not reject missing apiKeyRef in vllm.yaml'
grep -qF 'missing required vllm.auth.apiKeyRef entry' <<<"$out4" || fail 'rejection did not report missing apiKeyRef'
pass 'mutant 4: missing apiKeyRef rejected'

c5="$scratch/c5"; seed "$c5"
printf '\napiKey: "sk-literal-key-in-agents"\n' >> "$c5/.chezmoidata/agents.yaml"
out5=$("$checker" "$c5" 2>&1) && fail 'did not reject literal apiKey in non-vllm YAML'
grep -qF 'possible literal secret in tracked YAML' <<<"$out5" || fail 'rejection did not report literal secret in agents.yaml'
pass 'mutant 5: literal secret in non-vllm YAML rejected'

c6="$scratch/c6"; seed "$c6"
printf '\npackages:\n  leak: vllm_api_key=secret-literal-token\n' >> "$c6/.chezmoidata/packages.yaml"
out6=$("$checker" "$c6" 2>&1) && fail 'did not reject vllm_api_key assignment in packages.yaml'
grep -qF 'possible literal secret in tracked YAML' <<<"$out6" || fail 'rejection did not report vllm_api_key in packages.yaml'
pass 'mutant 6: vllm_api_key assignment in non-vllm YAML rejected'

c7="$scratch/c7"; seed "$c7"
printf '\nsystem:\n  token: "sk-12345678901234567890abcdef"\n' >> "$c7/.chezmoidata/system.yaml"
out7=$("$checker" "$c7" 2>&1) && fail 'did not reject token pattern in system.yaml'
grep -qF 'possible literal secret in tracked YAML' <<<"$out7" || fail 'rejection did not report token pattern in system.yaml'
pass 'mutant 7: token pattern in system.yaml rejected'

c8="$scratch/c8"; seed "$c8"
sed -i 's|apiKeyRef:.*|apiKeyRef: "literal-op://attempt"|' "$c8/.chezmoidata/vllm.yaml"
out8=$("$checker" "$c8" 2>&1) && fail 'did not reject substring-containing op:// literal'
grep -qF 'apiKeyRef must be an op:// reference' <<<"$out8" || fail 'rejection did not flag non-prefix op://'
pass 'mutant 8: substring suppression attempt rejected'

c9="$scratch/nonexistent-directory"
out9=$("$checker" "$c9" 2>&1) && fail 'did not reject nonexistent path'
grep -qF 'does not exist' <<<"$out9" || fail 'missing path failure did not report path does not exist'
pass 'mutant 9: nonexistent scan path rejected'

printf 'test-vllm-secret-refs: all tests passed\n'
