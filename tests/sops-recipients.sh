#!/usr/bin/env bash
# Checks every *.yaml, *.yml and *.json file under secrets/ in the tree at ROOT
# against .sops.yaml:
#
# - the age recipients stored in the file equal the recipients of the first
#   creation rule whose path_regex matches the file's repository-relative path,
#   which is how sops picks a rule. A rule only applies when a file is created
#   or re-keyed, so a recipient removed from a rule stays able to decrypt the
#   file until `sops updatekeys` runs.
# - the file matches a rule that names age recipients directly, carries a sops
#   block, and lists no key group other than age.
# - the tree holds at least one encrypted file.
#
# ROOT is read as given, so under nix it is the flake source, which holds only
# tracked files: stage a new secret file before trusting a local run.
#
# usage: sops-recipients.sh ROOT
set -euo pipefail

root=${1:?usage: sops-recipients.sh ROOT}
status=0

fail() {
  printf 'sops-recipients: %s\n' "$*" >&2
  status=1
}

# The age recipients, one per line and sorted, of the first .sops.yaml rule
# whose path_regex matches the repository-relative path $1; nothing when no
# rule matches.
rule_recipients() {
  FILE=$1 yq -r '[.creation_rules[] | . as $rule | select(strenv(FILE) | test($rule.path_regex // ""))][0].age // ""' "$root/.sops.yaml" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | sort -u
}

# Whether a rule matches $1 at all, as opposed to existing with no age
# recipients.
rule_matches() {
  [[ $(FILE=$1 yq -r '[.creation_rules[] | . as $rule | select(strenv(FILE) | test($rule.path_regex // ""))] | length' "$root/.sops.yaml") -gt 0 ]]
}

# Whether the first rule matching $1 spells its recipients as key_groups, which
# this check does not read; sops files encrypted that way hold no .sops.age.
rule_uses_key_groups() {
  [[ $(FILE=$1 yq -r '[.creation_rules[] | . as $rule | select(strenv(FILE) | test($rule.path_regex // ""))][0] | has("key_groups")' "$root/.sops.yaml") == true ]]
}

checked=0
while IFS= read -r file; do
  rel=${file#"$root"/}

  if [[ $(yq -r '.sops | type' "$file") != '!!map' ]]; then
    fail "$rel: has no sops block, so it is not encrypted"
    continue
  fi
  checked=$((checked + 1))

  if ! rule_matches "$rel"; then
    fail "$rel: matches no creation rule of .sops.yaml"
    continue
  fi

  if rule_uses_key_groups "$rel"; then
    fail "$rel: its .sops.yaml rule uses key_groups, which this check does not read; name the recipients in the rule's age list"
    continue
  fi

  for group in pgp kms gcp_kms azure_kv hc_vault key_groups; do
    if [[ $(yq -r ".sops.$group | length" "$file") -gt 0 ]]; then
      fail "$rel: lists a $group key group; only age recipients are allowed"
    fi
  done

  expected=$(rule_recipients "$rel")
  actual=$(yq -r '.sops.age[].recipient' "$file" | sort -u)
  while IFS= read -r recipient; do
    [[ -n $recipient ]] || continue
    fail "$rel: encrypted to $recipient, which its .sops.yaml rule does not name; run sops updatekeys $rel"
  done < <(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))
  while IFS= read -r recipient; do
    [[ -n $recipient ]] || continue
    fail "$rel: not encrypted to $recipient, which its .sops.yaml rule names; run sops updatekeys $rel"
  done < <(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))
done < <(find "$root/secrets" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) ! -name '.*' | sort)

if [[ $checked -eq 0 ]]; then
  fail "found no encrypted secrets/**/*.yaml under $root"
fi

printf 'sops-recipients: checked %d encrypted file(s) under %s\n' "$checked" "$root"
exit "$status"
