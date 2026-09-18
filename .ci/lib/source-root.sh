# shellcheck shell=bash
# .ci/lib/source-root.sh -- shared chezmoi source-root resolution, sourced
# (never executed directly).
#
# Today no `.chezmoiroot` exists anywhere in this checkout, so
# resolve_source_root is the identity function and every join below stays on
# the repository root: this file changes no behaviour on its own. Once a
# later unit adds `.chezmoiroot` at the repository root, chezmoi joins its
# trimmed content onto the source directory (see chezmoi's own
# getSourceDirAbsPath); resolve_source_root does the same starting from the
# repository root, and .ci/test-source-root.sh proves the two agree.
#
# The join-classification rule (plan Appendix): a path whose first segment is
# one of the exact source-state names below, or starts with dot_, private_,
# symlink_, or remove_, is source state and joins onto the resolved source
# root. Everything else -- including .ci, .github, docs, packages, crates,
# system, firmware, mise.toml, mise.lock, package.json,
# .install-prerequisites.sh, and .chezmoiroot itself -- is repository
# infrastructure and stays on the repository root unchanged.

_SOURCE_ROOT_EXACT_SEGMENTS=(
  ".chezmoi.toml.tmpl"
  ".chezmoidata"
  ".chezmoiexternals"
  ".chezmoiignore"
  ".chezmoiremove"
  ".chezmoiscripts"
  ".chezmoitemplates"
  ".keys"
  "Library"
)

# is_source_state_segment <segment>
#
# True when a path's first path component classifies it as source state per
# the rule above. Used by join_source_state (and so by require_file) to pick
# which root a path argument joins onto.
is_source_state_segment() {
  local segment=$1 name
  for name in "${_SOURCE_ROOT_EXACT_SEGMENTS[@]}"; do
    [[ "$segment" == "$name" ]] && return 0
  done
  case "$segment" in
    dot_* | private_* | symlink_* | remove_*) return 0 ;;
  esac
  return 1
}

# Trim leading and trailing whitespace (spaces, tabs, newlines) from $1.
_source_root_trim() {
  local value=$1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# resolve_source_root <root>
#
# Prints the source root chezmoi would read from <root> and returns 0. When
# <root>/.chezmoiroot is absent, <root> is the source root unchanged. When it
# is present, its whitespace-trimmed content is joined onto <root>; an empty,
# absolute, or parent-escaping value, or one naming a directory that does not
# exist, is refused with a diagnostic on stderr naming <root>/.chezmoiroot,
# and the function returns 1 and prints nothing.
resolve_source_root() {
  local root=$1 marker raw trimmed resolved
  marker="$root/.chezmoiroot"
  if [[ ! -f "$marker" ]]; then
    printf '%s\n' "$root"
    return 0
  fi
  raw=$(<"$marker")
  trimmed=$(_source_root_trim "$raw")
  if [[ -z "$trimmed" ]]; then
    printf '%s is empty\n' "$marker" >&2
    return 1
  fi
  if [[ "$trimmed" == /* ]]; then
    printf '%s names an absolute path: %s\n' "$marker" "$trimmed" >&2
    return 1
  fi
  if [[ "$trimmed" == *..* ]]; then
    printf '%s escapes its parent: %s\n' "$marker" "$trimmed" >&2
    return 1
  fi
  resolved="$root/$trimmed"
  if [[ ! -d "$resolved" ]]; then
    printf '%s names a directory that does not exist: %s\n' "$marker" "$trimmed" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

# join_source_state <repo_root> <path>
#
# Prints the absolute path <path> resolves to under the join-classification
# rule: onto the resolved source root when its first path segment is source
# state, else onto <repo_root> unchanged. Returns 1, with
# resolve_source_root's own diagnostic already on stderr and nothing printed,
# when <path> is source state and the source root fails to resolve.
join_source_state() {
  local repo_root=$1 path=$2 segment=${2%%/*} source_root
  if is_source_state_segment "$segment"; then
    source_root=$(resolve_source_root "$repo_root") || return 1
    printf '%s/%s\n' "$source_root" "$path"
  else
    printf '%s/%s\n' "$repo_root" "$path"
  fi
}

# SOURCE_ROOT_JOIN_PATTERN -- the name-anchored ERE .ci/test-source-root.sh's
# lint runs over `.ci/**/*.sh`: a literal `$repo_root`-style join (bare,
# braced, or quote-closed) straight onto a source-state name. It matches only
# a join whose target segment is spelled out in the source text, because a
# text lint has no runtime value to classify a variable with (a join such as
# `"$repo_root/$template"` is invisible to it by construction); those joins
# are made correct by resolve_source_root and join_source_state above
# instead, not caught by this pattern.
# shellcheck disable=SC2034 # read by .ci/test-source-root.sh, which sources this file.
SOURCE_ROOT_JOIN_PATTERN='\$\{?repo_root\}?"?/(\.chezmoi\.toml\.tmpl|\.chezmoidata|\.chezmoiexternals|\.chezmoiignore|\.chezmoiremove|\.chezmoiscripts|\.chezmoitemplates|\.keys|Library)([^A-Za-z0-9_.-]|$)|\$\{?repo_root\}?"?/(dot_|private_|symlink_|remove_)[A-Za-z0-9_.-]*'
