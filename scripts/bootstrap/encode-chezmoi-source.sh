#!/usr/bin/env bash

# encode-chezmoi-source.sh - One-shot migration tool for converting the home/
# tree into chezmoi source names by replacing each leading dot with dot_.
#
# Single-platform by design: this is a repository migration record, not a
# bootstrap helper, and is intentionally driven by POSIX find/mv from the
# migration task. There is no .ps1 counterpart (see scripts/README.md
# conventions).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
HOME_SOURCE="$REPO_ROOT/home"
REPO_PREFIX="$REPO_ROOT/"

if [[ ! -d "$HOME_SOURCE" ]]; then
  printf 'encode-chezmoi-source.sh: expected home source at %s.\n' "$HOME_SOURCE" >&2
  exit 1
fi

while IFS= read -r -d '' source_path; do
  basename="$(basename -- "$source_path")"

  case "$basename" in
    .chezmoi.toml.tmpl | .chezmoiignore.tmpl)
      continue
      ;;
  esac

  target_name="dot_${basename#.}"
  target_path="$(dirname -- "$source_path")/$target_name"

  if [[ -e "$target_path" || -L "$target_path" ]]; then
    printf 'encode-chezmoi-source.sh: refusing to overwrite existing path: %s\n' "$target_path" >&2
    exit 1
  fi

  mv -- "$source_path" "$target_path"
  printf '%s -> %s\n' "${source_path#"$REPO_PREFIX"}" "${target_path#"$REPO_PREFIX"}"
done < <(find "$HOME_SOURCE" -depth -name '.*' -print0)
