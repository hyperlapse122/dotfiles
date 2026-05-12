#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SECRETS_DIR="${SECRETS_DIR:-$HOME/.secrets}"

found=0

while IFS= read -r -d '' template_file; do
  found=1

  if ! command -v op >/dev/null 2>&1; then
    printf 'inject-1password-secrets.sh: op command not found. Install and sign in to 1Password CLI first.\n' >&2
    exit 1
  fi

  output_name="$(basename -- "${template_file%.1password}")"
  output_path="$SECRETS_DIR/$output_name"
  output_dir="$(dirname -- "$output_path")"

  mkdir -p -- "$SECRETS_DIR"
  chmod 700 -- "$SECRETS_DIR"
  mkdir -p -- "$output_dir"
  chmod 700 -- "$output_dir"

  op inject --force --in-file "$template_file" --out-file "$output_path"
  chmod 600 -- "$output_path"
done < <(find "$REPO_ROOT" -path "$REPO_ROOT/.git" -prune -o -type f -name '*.1password' -print0)

if [[ "$found" -eq 0 ]]; then
  printf 'inject-1password-secrets.sh: no *.1password files found under %s.\n' "$REPO_ROOT"
fi
