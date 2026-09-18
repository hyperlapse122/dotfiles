# shellcheck shell=bash disable=SC2154
# .ci/lib/ce-overlay-test.sh -- fixture helpers shared by
# .ci/test-ce-overlay-tooling.sh and .ci/test-ce-overlay-lock-hold.sh, sourced
# (never executed directly) after .ci/lib/ce-overlay.sh.
#
# The sourcing script sets $fx (the fixture root) and $effort (the roster
# authoring effort) before calling materialize.

materialize() { # <fixture subdirectory> <dest>
  local src=$fx/$1 dest=$2 file rel content
  while IFS= read -r -d '' file; do
    rel=${file#"$src"/}
    mkdir -p -- "$dest/$(dirname -- "$rel")"
    content=$(
      cat -- "$file"
      printf x
    )
    content=${content%x}
    printf '%s' "${content//@AUTHORING_EFFORT@/$effort}" >"$dest/$rel"
    case $rel in
      */elevation-dispatch.sh) chmod 0755 "$dest/$rel" ;;
      *) chmod 0644 "$dest/$rel" ;;
    esac
  done < <(find "$src" -type f -print0 | sort -z)
}

snapshot() { # <dir>
  local file
  while IFS= read -r file; do
    printf '%s %s\n' "$file" "$(ceo_sha256 "$1/$file")"
  done < <(cd -- "$1" && find . -type f | sort)
}
