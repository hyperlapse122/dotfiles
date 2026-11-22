#!/usr/bin/env bash
# Checks the secret layout of the tree at ROOT.
#
# For every host (a hosts/<host> directory), of either kind:
#
# - secrets/bootstrap/<host>/recipient.txt exists, and every
#   secrets/hosts/<host>/*.yaml is encrypted to that recorded recipient alone,
#   read from the encrypted file itself: a rule in .sops.yaml only applies when
#   a file is created or re-keyed, so the file is the authority on who can
#   decrypt it.
#
# For every Darwin host (a directory with host.nix), also:
#
# - secrets/hosts/<host>/ssh.yaml exists.
# - the shared credential files exist and each is encrypted to the recorded
#   bootstrap recipients. The rule alone cannot prove a new host can decrypt.
# - the shared credential files and any legacy rollback file omit docker_token.
# - the recipient is in neither the rule nor the encrypted file of wifi.yaml,
#   tailscale.yaml, and printers.yaml, so a Darwin host, whose identity
#   rests on the FileVault, never decrypts the Wi-Fi,
#   Tailscale, or printer material only NixOS hosts use.
#
# usage: user-identity-secrets.sh ROOT GROUP...
set -euo pipefail

root=${1:?usage: user-identity-secrets.sh ROOT GROUP...}
shift
[[ $# -gt 0 ]] || { echo 'no shared credential groups supplied' >&2; exit 1; }
status=0

fail() {
  printf 'user-identity-secrets: %s\n' "$*" >&2
  status=1
}

# The age recipients of the first .sops.yaml rule whose path_regex matches
# secrets/NAME.yaml, one per line.
rule_recipients() {
  FILE="secrets/$1.yaml" yq -r '[.creation_rules[] | . as $rule | select(strenv(FILE) | test($rule.path_regex // ""))][0].age // ""' "$root/.sops.yaml" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d'
}

# The age recipients secrets/NAME.yaml is encrypted to, read from the file;
# nothing when the file does not exist.
file_recipients() {
  local file=$root/secrets/$1.yaml
  [[ -f $file ]] || return 0
  yq -r '.sops.age[].recipient' "$file"
}

shopt -s nullglob
checked=0
darwin=0
recorded=()
for dir in "$root"/hosts/*/; do
  host=$(basename -- "$dir")
  checked=$((checked + 1))

  recipient_file=$root/secrets/bootstrap/$host/recipient.txt
  if [[ ! -f $recipient_file ]]; then
    fail "$host: secrets/bootstrap/$host/recipient.txt is missing"
    continue
  fi
  recipient=$(tr -d '[:space:]' <"$recipient_file")
  recorded+=("$recipient")

  for host_file in "$root/secrets/hosts/$host"/*.yaml; do
    actual=$(yq -r '.sops.age[].recipient' "$host_file" | sort -u)
    if [[ $actual != "$recipient" ]]; then
      fail "$host: secrets/hosts/$host/$(basename -- "$host_file") must be encrypted to this host's recipient alone, but lists: $(tr '\n' ' ' <<<"$actual")"
    fi
  done

  [[ -f $dir/host.nix ]] || continue
  darwin=$((darwin + 1))

  if [[ ! -f $root/secrets/hosts/$host/ssh.yaml ]]; then
    fail "$host: secrets/hosts/$host/ssh.yaml is missing"
  fi

  for other in wifi tailscale printers; do
    other_rule_recipients=$(rule_recipients "$other")
    if grep -qxF -- "$recipient" <<<"$other_rule_recipients"; then
      fail "$host: its recipient is in the $other.yaml rule of .sops.yaml; Darwin hosts must not decrypt it"
    fi
    other_file_recipients=$(file_recipients "$other")
    if grep -qxF -- "$recipient" <<<"$other_file_recipients"; then
      fail "$host: secrets/$other.yaml is encrypted to its recipient; Darwin hosts must not decrypt it"
    fi
  done
done

expected=$(printf '%s\n' "${recorded[@]}" | sort -u)
for group in "$@"; do
  if [[ ! -f $root/secrets/$group.yaml ]]; then
    fail "secrets/$group.yaml is missing"
  elif [[ $(file_recipients "$group" | sort -u) != "$expected" ]]; then
    fail "secrets/$group.yaml is not encrypted to exactly the recorded bootstrap recipients"
  fi
done

for group in "$@" tokens; do
  file=$root/secrets/$group.yaml
  [[ -f $file ]] || continue
  has_docker=$(yq -r 'has("docker_token")' "$file")
  if [[ $has_docker == true ]]; then
    fail "secrets/$group.yaml contains docker_token; use secrets/docker-registry.yaml"
  fi
done

if [[ $darwin -eq 0 ]]; then
  fail 'no Darwin hosts found'
fi
printf 'user-identity-secrets: checked %d host(s), %d of them Darwin, under %s\n' "$checked" "$darwin" "$root"
exit "$status"
