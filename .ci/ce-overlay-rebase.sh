#!/usr/bin/env bash
set -euo pipefail

# Rebase driver for the compound-engineering overlay patches. It moves the
# patches onto a new upstream release mechanically, and hands only the paths it
# cannot resolve to a person or to Claude. Only `finish`, `stamp`, and `seed`
# write the overlay directory.
#
# USAGE
#   ce-overlay-rebase.sh prepare --work-dir DIR [--target-tag TAG]
#   ce-overlay-rebase.sh finish  --work-dir DIR
#   ce-overlay-rebase.sh stamp   --target-tag TAG
#   ce-overlay-rebase.sh seed    --target-tag TAG --post KEY=FILE [--post ...] [--replace]
#
# COMMON OPTIONS
#   --overlay-dir DIR       overlay directory (default: the repository's own)
#   --lock FILE             release lock naming the upstream source (default:
#                           the repository's releases.json)
#   --pristine-dir DIR      upstream files at the target tag, replacing the download
#   --old-pristine-dir DIR  upstream files at base.json's tag, replacing the download
#
# prepare  Fetches upstream at base.json's tag and at the target tag (default:
#          base.json's tag, which gives a person the same editing loop). Routes
#          each patched path and writes DIR/manifest.json, DIR/pristine/<key> (the
#          target upstream file), and DIR/files/<key> (the patched result, with
#          conflict markers where a merge failed). Routes: unchanged, apply
#          (plain apply), 3way (three-way apply), conflict, collision (upstream
#          now ships an `absent` path), removed-upstream, broken-patch.
#          Exit: 0 every path resolved, 3 Claude is needed, 4 genuine failure
#          (removed-upstream, broken-patch, or an overlay that does not match
#          its own pin), 2 upstream unavailable.
#          Conflict markers name the sides: `upstream` is the new release and
#          `customization` is this repository's change.
# finish   Refuses unresolved conflict markers. Regenerates the patches and
#          base.json from DIR/files, writes them into the overlay directory, and
#          reports `customization=unchanged|changed`: unchanged when every
#          regenerated patch keeps the added and removed lines of the patch it
#          replaces, so only context lines moved. Exit 1 refuses and writes nothing.
# stamp    Rewrites only base.json's tag, and only when every pre-image at the
#          target tag equals the recorded one, mode included. Exit 1 refuses and
#          writes nothing, 2 upstream unavailable.
# seed     Builds a first patch set from post-image files against upstream at the
#          target tag. It refuses to replace an existing base.json without
#          --replace. A key that upstream lacks becomes an `absent` pre-image.
#
# Exit 64 is a usage error or a missing local tool. The download is the only
# network call; every test drives this script through --pristine-dir.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
# shellcheck source=.ci/lib/ce-overlay.sh
source "$repo_root/.ci/lib/ce-overlay.sh"

usage_error() {
  printf 'ce-overlay-rebase: %s\n' "$1" >&2
  exit 64
}

[[ $# -ge 1 ]] || usage_error 'a step is required: prepare, finish, stamp, or seed'
step=$1
shift

overlay_dir=''
lock=''
target=''
work_dir=''
pristine_src=''
old_pristine_src=''
replace=0
posts=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --replace)
      replace=1
      shift
      continue
      ;;
    --overlay-dir | --lock | --target-tag | --work-dir | --pristine-dir | --old-pristine-dir | --post)
      [[ $# -ge 2 ]] || usage_error "$1 needs a value"
      case $1 in
        --overlay-dir) overlay_dir=$2 ;;
        --lock) lock=$2 ;;
        --target-tag) target=$2 ;;
        --work-dir) work_dir=$2 ;;
        --pristine-dir) pristine_src=$2 ;;
        --old-pristine-dir) old_pristine_src=$2 ;;
        --post) posts+=("$2") ;;
      esac
      shift 2
      ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done

case $step in
  prepare | finish | stamp | seed) ;;
  *) usage_error "unknown step: $step" ;;
esac

if [[ -z $overlay_dir ]]; then
  overlay_dir=$(join_source_state "$repo_root" dot_local/share/compound-engineering-overlays)
fi
if [[ -z $lock ]]; then
  lock=$(join_source_state "$repo_root" .chezmoidata/releases.json)
fi
if [[ -n $target ]] && ! ceo_tag_valid "$target"; then
  usage_error "not a compound-engineering-v<semver> tag: $target"
fi

missing=$(ceo_missing_tool jq git tar awk find stat cmp) || true
[[ -z $missing ]] || usage_error "required tool not found: $missing"

scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
CEO_SCRATCH=$(mktemp -d "$scratch_root/ce-overlay-rebase.XXXXXX")
export CEO_SCRATCH
trap 'rm -rf -- "$CEO_SCRATCH"' EXIT
CEO_REPORT="$CEO_SCRATCH/report"
: >"$CEO_REPORT"
ceo_git_prepare "$CEO_SCRATCH/git-home"

keyfile="$CEO_SCRATCH/keys"
base="$overlay_dir/base.json"

refuse() { # <status> <message>
  ceo_report_print
  printf 'ce-overlay-rebase %s: %s\n' "$step" "$2" >&2
  exit "$1"
}

# A download needs the lock's source to be the allowlisted repository.
need_lock_for_download() {
  [[ -n $1 ]] && return 0
  missing=$(ceo_missing_tool curl) || true
  [[ -z $missing ]] || usage_error "required tool not found: $missing"
  ceo_read_lock "$lock" 0 || refuse "$2" 'the release lock does not name the allowlisted upstream'
}

# load_pristine <tag> <dest> <src-dir> <failure-status>
load_pristine() {
  local status=0
  ceo_load_pristine "$1" "$2" "$keyfile" "$3" || status=$?
  case $status in
    0) ;;
    2) refuse 2 "upstream unavailable for $1" ;;
    *) refuse "$4" "upstream at $1 is not usable" ;;
  esac
}

file_size() { wc -c <"$1" | tr -d ' '; }

# --- prepare -----------------------------------------------------------------

route_paths() { # sets $routes_tsv; expects $old $new $repo
  local key pre patch dest route theirs merge_status
  local empty_repo
  empty_repo=$(ceo_scratch_dir empty)
  ceo_repo_init "$empty_repo"
  : >"$routes_tsv"
  while IFS= read -r key; do
    patch="$overlay_dir/patches/$key.patch"
    dest="$work_dir/files/$key"
    pre=$(ceo_base_field "$base" "$key" '.preimage | if . == "absent" then "absent" else .sha256 + " " + .mode end')
    ceo_git -C "$repo" reset -q --hard HEAD
    ceo_git -C "$repo" clean -fdxq
    route=''
    if [[ ! -f $patch ]]; then
      route=broken-patch
    elif [[ $pre == absent ]]; then
      if [[ -f $new/$key ]]; then
        route=collision
        ceo_git -C "$empty_repo" clean -fdxq
        if ceo_git -C "$empty_repo" apply -- "$patch" 2>/dev/null; then
          : >"$CEO_SCRATCH/empty-base"
          theirs="$empty_repo/$key"
          mkdir -p -- "$(dirname -- "$dest")"
          merge_status=0
          ceo_git merge-file -p -L upstream -L base -L customization \
            "$new/$key" "$CEO_SCRATCH/empty-base" "$theirs" >"$dest" || merge_status=$?
          if [[ $merge_status -ge 128 ]]; then
            route=broken-patch
          else
            chmod "$(ceo_base_field "$base" "$key" .mode)" "$dest"
          fi
        else
          route=broken-patch
        fi
      elif ceo_git -C "$repo" apply -- "$patch" 2>/dev/null; then
        route=unchanged
      else
        route=broken-patch
      fi
    elif [[ ! -f $new/$key ]]; then
      route=removed-upstream
    elif [[ "$(ceo_sha256 "$new/$key") $(ceo_mode "$new/$key")" == "$pre" ]]; then
      if ceo_git -C "$repo" apply -- "$patch" 2>/dev/null; then route=unchanged; else route=broken-patch; fi
    elif ceo_git -C "$repo" apply -- "$patch" 2>/dev/null; then
      route=apply
    else
      ceo_git -C "$repo" reset -q --hard HEAD
      ceo_git -C "$repo" clean -fdxq
      if ceo_git -C "$repo" apply --3way -- "$patch" 2>/dev/null; then
        route=3way
      else
        route=conflict
      fi
    fi
    case $route in
      unchanged | apply | 3way)
        mkdir -p -- "$(dirname -- "$dest")"
        cp -p -- "$repo/$key" "$dest"
        ;;
      conflict)
        if grep -qE '^<<<<<<< ' "$repo/$key" 2>/dev/null; then
          mkdir -p -- "$(dirname -- "$dest")"
          sed -e 's/^<<<<<<< ours$/<<<<<<< upstream/' -e 's/^>>>>>>> theirs$/>>>>>>> customization/' \
            "$repo/$key" >"$dest"
          chmod "$(ceo_mode "$repo/$key")" "$dest"
        else
          route=broken-patch
        fi
        ;;
    esac
    if [[ -f $dest && ! -L $dest ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$route" "$(ceo_mode "$dest")" "$(ceo_sha256 "$dest")" "$(file_size "$dest")" >>"$routes_tsv"
    else
      printf '%s\t%s\t-\t-\t-\n' "$key" "$route" >>"$routes_tsv"
    fi
  done <"$keyfile"
}

step_prepare() {
  local old new repo routes_tsv base_tag key route genuine=0 needs_claude=0
  [[ -n $work_dir ]] || usage_error 'prepare needs --work-dir'
  if [[ -e $work_dir ]] && [[ -n $(ls -A -- "$work_dir") ]]; then
    usage_error "work directory is not empty: $work_dir"
  fi
  mkdir -p -- "$work_dir"
  work_dir=$(cd -- "$work_dir" && pwd)
  ceo_base_validate "$base" "$keyfile" || refuse 4 'base.json is not valid'
  ceo_check_overlay_layout "$overlay_dir" "$keyfile" 1 || refuse 4 'the patches do not match base.json'
  base_tag=$(jq -r '.version' "$base")
  target=${target:-$base_tag}

  need_lock_for_download "$old_pristine_src" 4
  need_lock_for_download "$pristine_src" 4
  old="$CEO_SCRATCH/old"
  load_pristine "$base_tag" "$old" "$old_pristine_src" 4
  ceo_check_preimages "$base" "$keyfile" "$old" || refuse 4 "the recorded pre-images do not match upstream at $base_tag"
  if [[ $target == "$base_tag" && -z $pristine_src ]]; then
    new=$old
  else
    new="$CEO_SCRATCH/new"
    load_pristine "$target" "$new" "$pristine_src" 4
  fi

  repo=$(ceo_scratch_dir route)
  ceo_repo_init "$repo"
  while IFS= read -r key; do
    if [[ -f $old/$key ]]; then
      mkdir -p -- "$repo/$(dirname -- "$key")"
      cp -p -- "$old/$key" "$repo/$key"
    fi
  done <"$keyfile"
  ceo_repo_commit "$repo" old
  while IFS= read -r key; do
    rm -f -- "${repo:?}/$key"
    if [[ -f $new/$key ]]; then
      mkdir -p -- "$repo/$(dirname -- "$key")"
      cp -p -- "$new/$key" "$repo/$key"
    fi
  done <"$keyfile"
  ceo_repo_commit "$repo" new

  routes_tsv="$CEO_SCRATCH/routes.tsv"
  route_paths

  while IFS= read -r key; do
    if [[ -f $new/$key ]]; then
      mkdir -p -- "$work_dir/pristine/$(dirname -- "$key")"
      cp -p -- "$new/$key" "$work_dir/pristine/$key"
    fi
  done <"$keyfile"
  jq -Rn --arg base "$base_tag" --arg target "$target" '
    [inputs | split("\t") | {key: .[0], value: {
      route: .[1],
      mode: (if .[2] == "-" then null else .[2] end),
      sha256: (if .[3] == "-" then null else .[3] end),
      size: (if .[4] == "-" then null else (.[4] | tonumber) end)}}]
    | sort_by(.key) | from_entries as $paths
    | {baseTag: $base, targetTag: $target, paths: $paths,
       conflicted: [$paths | to_entries[] | select(.value.route == "conflict" or .value.route == "collision") | .key]}
  ' <"$routes_tsv" >"$work_dir/manifest.json"

  while IFS=$'\t' read -r key route _; do
    printf 'route=%s path=%s\n' "$route" "$key"
    case $route in
      removed-upstream | broken-patch) genuine=1 ;;
      conflict | collision) needs_claude=1 ;;
    esac
  done <"$routes_tsv"
  if [[ $genuine == 1 ]]; then
    printf 'result=genuine\n'
    exit 4
  fi
  if [[ $needs_claude == 1 ]]; then
    printf 'result=claude\n'
    exit 3
  fi
  printf 'result=resolved\n'
}

# --- finish ------------------------------------------------------------------

install_stage() { # <stage-dir>
  local key
  while IFS= read -r key; do
    mkdir -p -- "$overlay_dir/patches/$(dirname -- "$key")"
    cp -- "$1/patches/$key.patch" "$overlay_dir/patches/$key.patch"
  done <"$keyfile"
  cp -- "$1/base.json" "$overlay_dir/base.json.new"
  mv -f -- "$overlay_dir/base.json.new" "$overlay_dir/base.json"
}

step_finish() {
  local manifest key route marker stage spec target_tag old_patch overall=unchanged verdict
  [[ -n $work_dir ]] || usage_error 'finish needs --work-dir'
  manifest="$work_dir/manifest.json"
  [[ -f $manifest ]] || refuse 1 "no manifest in the work directory: $manifest"
  jq -e '(keys == ["baseTag", "conflicted", "paths", "targetTag"]) and (.paths | type == "object" and length > 0)' \
    "$manifest" >/dev/null 2>&1 || refuse 1 'the manifest does not match its schema'
  target_tag=$(jq -r '.targetTag' "$manifest")
  ceo_tag_valid "$target_tag" || refuse 1 "the manifest target is not a release tag: $target_tag"
  jq -r '.paths | keys[]' "$manifest" >"$keyfile"
  while IFS= read -r key; do
    ceo_key_valid "$key" || refuse 1 "the manifest holds an unsafe path: $key"
  done <"$keyfile"
  ceo_base_validate "$base" "$CEO_SCRATCH/base-keys" || refuse 1 'base.json is not valid'
  cmp -s "$keyfile" "$CEO_SCRATCH/base-keys" || refuse 1 'the manifest and base.json name different paths'

  spec="$CEO_SCRATCH/spec"
  : >"$spec"
  while IFS= read -r key; do
    route=$(jq -r --arg key "$key" '.paths[$key].route' "$manifest")
    case $route in
      removed-upstream | broken-patch)
        refuse 1 "$key is $route and needs a design decision, not a merge"
        ;;
    esac
    if [[ ! -f $work_dir/files/$key || -L $work_dir/files/$key ]]; then
      refuse 1 "the work file is missing: files/$key"
    fi
    marker=$(grep -nE '^(<<<<<<<|>>>>>>>)( |$)' "$work_dir/files/$key" | head -n1 || true)
    if [[ -n $marker ]]; then
      refuse 1 "unresolved conflict marker in $key at line ${marker%%:*}"
    fi
    printf '%s\t%s\n' "$key" "$(jq -r --arg key "$key" '.paths[$key].mode' "$manifest")" >>"$spec"
  done <"$keyfile"

  stage=$(ceo_scratch_dir stage)
  ceo_generate "$stage" "$work_dir/pristine" "$work_dir/files" "$target_tag" "$spec" \
    || refuse 1 'the work files do not produce a valid patch set'

  while IFS= read -r key; do
    old_patch="$overlay_dir/patches/$key.patch"
    verdict=changed
    if [[ -f $old_patch ]] && cmp -s <(ceo_patch_change_lines "$old_patch") <(ceo_patch_change_lines "$stage/patches/$key.patch"); then
      verdict=unchanged
    fi
    [[ $verdict == unchanged ]] || overall=changed
    printf 'path=%s customization=%s\n' "$key" "$verdict"
  done <"$keyfile"

  install_stage "$stage"
  printf 'customization=%s\n' "$overall"
}

# --- stamp -------------------------------------------------------------------

step_stamp() {
  local base_tag
  [[ -n $target ]] || usage_error 'stamp needs --target-tag'
  ceo_base_validate "$base" "$keyfile" || refuse 1 'base.json is not valid'
  need_lock_for_download "$pristine_src" 1
  load_pristine "$target" "$CEO_SCRATCH/new" "$pristine_src" 1
  ceo_check_preimages "$base" "$keyfile" "$CEO_SCRATCH/new" \
    || refuse 1 "a pre-image at $target differs from the recorded one; run prepare instead"
  base_tag=$(jq -r '.version' "$base")
  jq --arg version "$target" '.version = $version' "$base" >"$overlay_dir/base.json.new"
  mv -f -- "$overlay_dir/base.json.new" "$base"
  printf 'stamped=%s previous=%s\n' "$target" "$base_tag"
}

# --- seed --------------------------------------------------------------------

step_seed() {
  local post key file files stage spec seen=''
  [[ -n $target ]] || usage_error 'seed needs --target-tag'
  [[ ${#posts[@]} -gt 0 ]] || usage_error 'seed needs at least one --post KEY=FILE'
  if [[ -e $base && $replace == 0 ]]; then
    usage_error "base.json already exists; pass --replace to regenerate it: $base"
  fi
  files=$(ceo_scratch_dir files)
  spec="$CEO_SCRATCH/spec"
  : >"$spec"
  for post in "${posts[@]}"; do
    key=${post%%=*}
    file=${post#*=}
    [[ $post == *=* ]] || usage_error "--post needs KEY=FILE: $post"
    ceo_key_valid "$key" || usage_error "not a safe relative path: $key"
    [[ -f $file && ! -L $file ]] || usage_error "post-image is not a regular file: $file"
    case " $seen " in *" $key "*) usage_error "duplicate --post key: $key" ;; esac
    seen="$seen $key"
    mkdir -p -- "$files/$(dirname -- "$key")"
    cp -- "$file" "$files/$key"
    printf '%s\t%s\n' "$key" "$(ceo_mode "$file")" >>"$spec"
  done
  cut -f1 "$spec" | sort >"$keyfile"
  need_lock_for_download "$pristine_src" 1
  load_pristine "$target" "$CEO_SCRATCH/new" "$pristine_src" 1
  stage=$(ceo_scratch_dir stage)
  ceo_generate "$stage" "$CEO_SCRATCH/new" "$files" "$target" "$spec" \
    || refuse 1 'the post-images do not produce a valid patch set'
  mkdir -p -- "$overlay_dir"
  install_stage "$stage"
  printf 'seeded=%s paths=%s\n' "$target" "$(wc -l <"$keyfile" | tr -d ' ')"
}

case $step in
  prepare) step_prepare ;;
  finish) step_finish ;;
  stamp) step_stamp ;;
  seed) step_seed ;;
esac
