# shellcheck shell=bash
# .ci/lib/ce-overlay.sh -- shared functions for the compound-engineering overlay
# patch tooling, sourced (never executed directly) by
# .ci/check-ce-overlay-patches.sh, .ci/ce-overlay-rebase.sh and
# .ci/test-ce-overlay-tooling.sh.
#
# CALLER CONTRACT. The sourcing script owns these globals and sets them before
# calling anything here:
#   CEO_SCRATCH  a private scratch directory, removed by the caller's trap
#   CEO_REPORT   a file that collects `<class>\t<path>\t<message>` lines
#   CEO_GIT_HOME a directory git uses as HOME (set by ceo_git_prepare)
#
# RETURN CONVENTION. A function that can fail on upstream data returns 0 on
# success, 1 when the data is invalid (it has appended a report line naming the
# class), and 2 when upstream could not be fetched or unpacked. Only 2 means
# "unavailable": a malformed or hostile archive is never 2.
#
# The archive download is the only network call in this file.

# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/render-gate-helpers.sh"

CEO_OWNER_REPO='everyinc/compound-engineering-plugin'
CEO_TAG_PATTERN='^compound-engineering-v[0-9]+\.[0-9]+\.[0-9]+$'
CEO_KEY_PATTERN='^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$'
CEO_CLASS_PRIORITY='schema version-mismatch coverage removed-upstream collision preimage-mismatch patch-conflict postimage-mismatch contract'
CEO_PERSONA_KEY='skills/ce-sweep/references/sources/gitlab-issues.md'
CEO_INTERVIEW_KEY='skills/ce-sweep/references/interview.md'
CEO_ADAPTER_KEYS='skills/ce-plan/scripts/elevation-dispatch.sh skills/ce-brainstorm/scripts/elevation-dispatch.sh'

CEO_PERSONA_STRINGS=(
  'glab'
  'group/project#<iid>'
  'confidential'
  'sensitive: true'
  'GitLab tools unavailable — source skipped this run.'
  'GitLab write capability unavailable — source degrades to read-only ingest; items will be marked ack_deferred.'
  'glab issue update <iid> --repo <group/project> --label <configured-label>'
  '--order updated_at --sort desc --output json --page <n> --per-page 100'
  'updated_at >= cursor'
  'members/all/<author-id>'
  'Confidential GitLab issue group/project#<iid>'
  'Fetch is all-or-nothing.'
  'During fetch, use only `glab` read commands'
  'Empty list when none or when the issue is confidential'
)
CEO_INTERVIEW_STRINGS=('gitlab-issues' 'group/project' 'feedback:ack' 'feedback:resolved')

CEO_BASE_SCHEMA='
  def hex: type == "string" and test("^[0-9a-f]{64}$");
  def mode: . == "0644" or . == "0755";
  type == "object" and (keys == ["paths", "version"])
  and (.version | type == "string")
  and (.paths | type == "object" and length > 0)
  and all(.paths | to_entries[];
        (.value | type == "object" and (keys == ["mode", "postimage", "preimage"]))
        and (.value.mode | mode)
        and (.value.postimage | type == "object" and (keys == ["sha256"]) and (.sha256 | hex))
        and (.value.preimage == "absent"
             or (.value.preimage | type == "object" and (keys == ["mode", "sha256"])
                 and (.mode | mode) and (.sha256 | hex))))
'

ceo_tag_valid() { [[ ${1-} =~ $CEO_TAG_PATTERN ]]; }

ceo_segment() { printf 'v%s' "${1#compound-engineering-v}"; }

ceo_key_valid() {
  local key=${1-} segment
  local -a segments
  [[ $key =~ $CEO_KEY_PATTERN ]] || return 1
  IFS=/ read -r -a segments <<<"$key"
  for segment in "${segments[@]}"; do
    case $segment in . | .. | .git) return 1 ;; esac
  done
}

ceo_missing_tool() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || {
      printf '%s' "$tool"
      return 0
    }
  done
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || {
    printf 'sha256sum'
    return 0
  }
  return 1
}

ceo_report() { printf '%s\t%s\t%s\n' "$1" "${2:--}" "$3" >>"$CEO_REPORT"; }

ceo_pick_class() {
  local class
  for class in $CEO_CLASS_PRIORITY; do
    if cut -f1 "$CEO_REPORT" | grep -qxF -- "$class"; then
      printf '%s' "$class"
      return 0
    fi
  done
  return 1
}

ceo_report_print() {
  local class key message
  while IFS=$'\t' read -r class key message; do
    printf '  %s %s: %s\n' "$class" "$key" "$message" >&2
  done <"$CEO_REPORT"
}

ceo_scratch_dir() { mktemp -d "$CEO_SCRATCH/${1:-tmp}.XXXXXX"; }

ceo_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | cut -d' ' -f1
  else
    shasum -a 256 -- "$1" | cut -d' ' -f1
  fi
}

# Reads permission bits with stat rather than `[ -x ]`: access(2) reports
# EACCES for X_OK on a noexec mount, which would misread every file as 0644.
ceo_mode() {
  local perm
  perm=$(stat -c '%a' -- "$1" 2>/dev/null || stat -f '%Lp' -- "$1") || return 1
  if ((8#$perm & 8#100)); then printf '0755'; else printf '0644'; fi
}

# --- lock and source ---------------------------------------------------------

# ceo_read_lock <releases.json> <require-pin: 0|1> -> CEO_PIN
# The lock never chooses the download host: only the allowlisted repository is
# accepted, whatever spelling the lock uses.
ceo_read_lock() {
  local lock=$1 require_pin=$2 entry source
  CEO_PIN=''
  if [[ ! -f $lock ]] || ! entry=$(jq -er '.releases.tools["compound-engineering"] | [.source, .version] | @tsv' "$lock" 2>/dev/null); then
    ceo_report schema - "lock has no compound-engineering entry: $lock"
    return 1
  fi
  source=${entry%%$'\t'*}
  CEO_PIN=${entry#*$'\t'}
  if [[ ${source,,} != "$CEO_OWNER_REPO" ]]; then
    ceo_report schema - "lock source is not $CEO_OWNER_REPO: $source"
    return 1
  fi
  if [[ $require_pin == 1 ]] && ! ceo_tag_valid "$CEO_PIN"; then
    ceo_report schema - "lock version is not a compound-engineering-v<semver> tag: $CEO_PIN"
    return 1
  fi
}

# --- base.json ---------------------------------------------------------------

# ceo_base_validate <base.json> <keyfile-out>
ceo_base_validate() {
  local file=$1 keyfile=$2 key version
  if [[ ! -f $file || -L $file ]]; then
    ceo_report schema base.json "base.json is missing: $file"
    return 1
  fi
  if ! jq -e "$CEO_BASE_SCHEMA" "$file" >/dev/null 2>&1; then
    ceo_report schema base.json 'base.json does not match the schema'
    return 1
  fi
  version=$(jq -r '.version' "$file")
  if ! ceo_tag_valid "$version"; then
    ceo_report schema base.json "base.json version is not a compound-engineering-v<semver> tag: $version"
    return 1
  fi
  jq -r '.paths | keys[]' "$file" >"$keyfile"
  while IFS= read -r key; do
    if ! ceo_key_valid "$key"; then
      ceo_report schema "$key" 'base.json key is not a safe relative path'
      return 1
    fi
  done <"$keyfile"
}

# ceo_base_render <version> < "<key>\t<pre-sha|absent>\t<pre-mode|->\t<post-sha>\t<mode>" lines
ceo_base_render() {
  jq -Rn --arg version "$1" '
    [inputs | split("\t") | {key: .[0], value: {
      preimage: (if .[1] == "absent" then "absent" else {sha256: .[1], mode: .[2]} end),
      postimage: {sha256: .[3]},
      mode: .[4]}}]
    | sort_by(.key)
    | {version: $version, paths: from_entries}'
}

ceo_base_field() { # <base.json> <key> <jq filter applied to the entry>
  jq -r --arg key "$2" ".paths[\$key]$3" "$1"
}

# --- git ---------------------------------------------------------------------

ceo_git_prepare() {
  CEO_GIT_HOME=$1
  mkdir -p -- "$CEO_GIT_HOME"
}

# Every scratch repository is its own git boundary and reads no user or system
# configuration, so the same patch applies the same way on every host and an
# enclosing repository can never make `git apply` skip a path silently.
ceo_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR -u GIT_NAMESPACE \
    -u GIT_EXTERNAL_DIFF -u GIT_DIFF_OPTS \
    HOME="$CEO_GIT_HOME" XDG_CONFIG_HOME="$CEO_GIT_HOME" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_ATTR_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat LC_ALL=C \
    git -c core.autocrlf=false -c core.safecrlf=false -c core.filemode=true \
    -c core.symlinks=true -c core.hooksPath=/dev/null -c core.quotepath=off \
    -c commit.gpgsign=false -c user.name=ce-overlay -c user.email=ce-overlay@invalid \
    -c init.defaultBranch=main -c apply.whitespace=nowarn \
    -c diff.renames=false -c diff.noprefix=false -c diff.mnemonicPrefix=false \
    "$@" </dev/null
}

ceo_repo_init() {
  mkdir -p -- "$1"
  ceo_git init -q -- "$1" >/dev/null
}

ceo_repo_commit() { # <repo> <message>
  ceo_git -C "$1" add -A -f -- . >/dev/null
  ceo_git -C "$1" commit -q --allow-empty --no-verify --no-gpg-sign -m "$2" >/dev/null
}

# --- patches -----------------------------------------------------------------

# Accepts exactly one path per patch, spelled with the base.json key, and
# rejects rename, copy, delete, and binary forms.
ceo_patch_headers_ok() { # <patch> <key>
  awk -v key="$2" '
    /^diff --git / {
      diffs++
      inhunk = 0
      if ($0 != "diff --git a/" key " b/" key) bad = 1
      next
    }
    /^@@ / { inhunk = 1; next }
    inhunk { next }
    /^(rename|copy) (from|to) / || /^(dis)?similarity index / || /^deleted file mode / { bad = 1; next }
    /^(GIT binary patch|Binary files )/ { bad = 1; next }
    /^--- / {
      olds++
      if ($0 != "--- a/" key && $0 != "--- /dev/null") bad = 1
      next
    }
    /^\+\+\+ / {
      news++
      if ($0 != "+++ b/" key) bad = 1
      next
    }
    END { exit (diffs == 1 && olds == 1 && news == 1 && !bad) ? 0 : 1 }
  ' "$1"
}

# The added and removed lines of a patch, in order, without hunk headers or
# context. Two patches with equal output differ only in where their hunks sit.
ceo_patch_change_lines() {
  awk '/^diff --git / { inhunk = 0 } /^@@ / { inhunk = 1; next } inhunk && /^[+-]/ { print }' "$1"
}

# ceo_check_overlay_layout <overlay-dir> <keyfile> <allow-legacy: 0|1>
# Every key has a patch and every patch has a key, always. Anything outside
# patches/** and base.json is refused unless allow-legacy is 1.
ceo_check_overlay_layout() {
  local dir=$1 keyfile=$2 legacy=$3 key path rel patch
  if [[ -L $dir/patches ]]; then
    ceo_report coverage patches 'patches is a symlink'
  fi
  while IFS= read -r key; do
    patch="$dir/patches/$key.patch"
    if [[ ! -f $patch || -L $patch ]]; then
      ceo_report coverage "$key" "patch file is missing: patches/$key.patch"
    elif ! ceo_patch_headers_ok "$patch" "$key"; then
      ceo_report coverage "$key" 'patch header names another path, a rename, a delete, or a binary change'
    fi
  done <"$keyfile"
  while IFS= read -r -d '' path; do
    rel=${path#"$dir"/}
    case $rel in
      base.json)
        if [[ -L $path ]]; then ceo_report coverage "$rel" 'base.json is a symlink'; fi
        ;;
      patches/*)
        key=${rel#patches/}
        if [[ -L $path || $key != *.patch ]]; then
          ceo_report coverage "$rel" 'only regular .patch files may sit under patches/'
        elif ! grep -qxF -- "${key%.patch}" "$keyfile"; then
          ceo_report coverage "$rel" 'patch has no base.json entry'
        fi
        ;;
      *)
        if [[ $legacy == 0 ]]; then
          ceo_report coverage "$rel" 'the overlay directory holds only patches/** and base.json'
        fi
        ;;
    esac
  done < <(find "$dir" -mindepth 1 ! -type d -print0 | sort -z)
  ! grep -q "^coverage" "$CEO_REPORT"
}

# ceo_apply_patches <pristine-dir> <patch-dir> <keyfile> <out-dir>
# Applies patches/<key>.patch to a copy of pristine/<key> inside a scratch
# repository and copies each result to out-dir/<key>. One path failing does not
# stop the others; the caller reads the report. keyfile's first column is the key.
ceo_apply_patches() {
  local pristine=$1 patches=$2 keyfile=$3 out=$4 repo key status=0 err
  repo=$(ceo_scratch_dir apply)
  err="$repo.err"
  ceo_repo_init "$repo"
  while IFS=$'\t' read -r key _; do
    if [[ -f $pristine/$key ]]; then
      mkdir -p -- "$repo/$(dirname -- "$key")"
      cp -p -- "$pristine/$key" "$repo/$key"
    fi
  done <"$keyfile"
  while IFS=$'\t' read -r key _; do
    if ceo_git -C "$repo" apply -- "$patches/$key.patch" 2>"$err" && [[ -f $repo/$key && ! -L $repo/$key ]]; then
      mkdir -p -- "$out/$(dirname -- "$key")"
      cp -p -- "$repo/$key" "$out/$key"
    else
      ceo_report patch-conflict "$key" "patch does not apply: $(head -c 300 "$err" | tr '\n' ' ')"
      status=1
    fi
  done <"$keyfile"
  return "$status"
}

# ceo_generate <stage-dir> <pristine-dir> <files-dir> <tag> <spec>
# spec lines are "<key>\t<mode>". A key with no pristine file gets an `absent`
# pre-image and a patch that creates it. Writes stage/patches/<key>.patch and
# stage/base.json, then proves each patch reproduces its recorded post-image.
ceo_generate() {
  local stage=$1 pristine=$2 files=$3 tag=$4 spec=$5
  local repo key mode tsv verify status=0
  repo=$(ceo_scratch_dir gen)
  tsv="$repo.tsv"
  ceo_repo_init "$repo"
  while IFS=$'\t' read -r key mode; do
    if [[ -f $pristine/$key ]]; then
      mkdir -p -- "$repo/$(dirname -- "$key")"
      cp -p -- "$pristine/$key" "$repo/$key"
    fi
  done <"$spec"
  ceo_repo_commit "$repo" pristine
  : >"$tsv"
  while IFS=$'\t' read -r key mode; do
    if [[ ! -f $files/$key || -L $files/$key ]]; then
      ceo_report schema "$key" 'working file is missing or not a regular file'
      return 1
    fi
    mkdir -p -- "$repo/$(dirname -- "$key")" "$stage/patches/$(dirname -- "$key")"
    cp -- "$files/$key" "$repo/$key"
    chmod "$mode" "$repo/$key"
    if [[ ! -f $pristine/$key ]]; then
      ceo_git -C "$repo" add -N -- "$key"
    fi
    ceo_git -C "$repo" diff --full-index --no-renames --no-color --no-ext-diff \
      --src-prefix=a/ --dst-prefix=b/ -- "$key" >"$stage/patches/$key.patch"
    if [[ ! -s $stage/patches/$key.patch ]]; then
      ceo_report contract "$key" 'no customization remains: the working file equals upstream'
      status=1
      continue
    fi
    if [[ -f $pristine/$key ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$(ceo_sha256 "$pristine/$key")" "$(ceo_mode "$pristine/$key")" \
        "$(ceo_sha256 "$repo/$key")" "$mode" >>"$tsv"
    else
      printf '%s\tabsent\t-\t%s\t%s\n' "$key" "$(ceo_sha256 "$repo/$key")" "$mode" >>"$tsv"
    fi
  done <"$spec"
  [[ $status == 0 ]] || return 1
  ceo_base_render "$tag" <"$tsv" >"$stage/base.json"
  verify=$(ceo_scratch_dir verify)
  ceo_apply_patches "$pristine" "$stage/patches" "$spec" "$verify" || return 1
  while IFS=$'\t' read -r key mode; do
    if [[ $(ceo_sha256 "$verify/$key") != "$(ceo_base_field "$stage/base.json" "$key" .postimage.sha256)" ]]; then
      ceo_report postimage-mismatch "$key" 'the regenerated patch does not reproduce the working file'
      status=1
    fi
  done <"$spec"
  return "$status"
}

# --- pristine upstream -------------------------------------------------------

# ceo_stage_pristine_dir <src-dir> <dest-dir> <keyfile>
# A staged tree holds only regular files at base.json keys, reached without
# crossing a symlink.
ceo_stage_pristine_dir() {
  local src=$1 dest=$2 keyfile=$3 key prefix segment
  local -a segments
  while IFS= read -r key; do
    prefix=$src
    IFS=/ read -r -a segments <<<"$key"
    for segment in "${segments[@]}"; do
      prefix="$prefix/$segment"
      if [[ -L $prefix ]]; then
        ceo_report schema "$key" 'pristine path crosses a symlink'
        return 1
      fi
    done
    [[ -e $src/$key ]] || continue
    if [[ ! -f $src/$key ]]; then
      ceo_report schema "$key" 'pristine path is not a regular file'
      return 1
    fi
    mkdir -p -- "$dest/$(dirname -- "$key")"
    cp -p -- "$src/$key" "$dest/$key"
  done <"$keyfile"
}

ceo_download() { # <tag> <archive-out>
  local url attempt=1 header delay=${CE_OVERLAY_FETCH_RETRY_DELAY:-5}
  local -a auth=()
  url="https://github.com/$CEO_OWNER_REPO/archive/refs/tags/$1.tar.gz"
  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    header="$(ceo_scratch_dir hdr)/header"
    (umask 077 && printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" >"$header")
    auth=(--header "@$header")
  fi
  while :; do
    if curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 20 --max-time 180 "${auth[@]+"${auth[@]}"}" --output "$2" -- "$url" 2>/dev/null; then
      return 0
    fi
    [[ $attempt -lt 3 ]] || break
    attempt=$((attempt + 1))
    sleep "$delay"
  done
  ceo_report unavailable - "download failed after 3 attempts: $url"
  return 2
}

# "<name>\t<type characters>" for each name in the names file, read from a
# verbose tar listing. GNU tar and bsdtar both print a link as
# "<name> -> <target>" or "<name> link to <target>" after the name.
ceo_tar_types() { # <verbose-listing> <names-file>
  awk -v names="$2" '
    BEGIN { while ((getline n < names) > 0) want[n] = 1 }
    {
      line = $0
      type = substr(line, 1, 1)
      sub(/ -> .*$/, "", line)
      sub(/ link to .*$/, "", line)
      for (n in want) {
        l = length(n)
        if (length(line) > l && substr(line, length(line) - l) == " " n) types[n] = types[n] type
      }
    }
    END { for (n in want) print n "\t" types[n] }
  ' "$1"
}

# ceo_extract_archive <archive> <dest-dir> <keyfile>
# Unpacks only the members named by base.json keys, only as regular files. A
# link, a `..` component, or an absolute name is hostile input, not an outage.
ceo_extract_archive() {
  local archive=$1 dest=$2 keyfile=$3 work top key name type ancestor i
  local -a members=() segments
  work=$(ceo_scratch_dir extract)
  if ! tar -tzf "$archive" >"$work/names" 2>/dev/null || [[ ! -s $work/names ]]; then
    ceo_report unavailable - 'archive cannot be listed'
    return 2
  fi
  if awk '/^\// || /(^|\/)\.\.(\/|$)/ { found = 1 } END { exit !found }' "$work/names"; then
    ceo_report schema - 'archive holds an absolute or ".." member name'
    return 1
  fi
  top=$(head -n1 "$work/names")
  top=${top%%/*}
  : >"$work/wanted"
  : >"$work/present"
  while IFS= read -r key; do
    printf '%s\n' "$top/$key" >>"$work/wanted"
    IFS=/ read -r -a segments <<<"$key"
    ancestor=$top
    for ((i = 0; i < ${#segments[@]} - 1; i++)); do
      ancestor="$ancestor/${segments[i]}"
      printf '%s\n' "$ancestor" >>"$work/wanted"
    done
    if grep -qxF -- "$top/$key" "$work/names"; then
      printf '%s\n' "$key" >>"$work/present"
      members+=("$top/$key")
    fi
  done <"$keyfile"
  printf '%s\n' "$top" >>"$work/wanted"
  if ! tar -tvzf "$archive" >"$work/verbose" 2>/dev/null; then
    ceo_report unavailable - 'archive cannot be listed'
    return 2
  fi
  while IFS=$'\t' read -r name type; do
    key=${name#"$top/"}
    if [[ $type == *[lh]* ]]; then
      ceo_report schema "$key" 'archive holds a link at a patched path or one of its parent directories'
      return 1
    fi
    if grep -qxF -- "$key" "$work/present" && [[ $type != '-' ]]; then
      ceo_report schema "$key" "archive member is not a regular file (type '${type:-none}')"
      return 1
    fi
  done < <(ceo_tar_types "$work/verbose" "$work/wanted")
  if ((${#members[@]} > 0)); then
    mkdir -p -- "$work/out"
    if ! tar -xzf "$archive" -C "$work/out" --no-same-owner -- "${members[@]}" 2>/dev/null; then
      ceo_report unavailable - 'archive extraction failed'
      return 2
    fi
    while IFS= read -r key; do
      if [[ ! -f $work/out/$top/$key || -L $work/out/$top/$key ]]; then
        ceo_report schema "$key" 'extracted member is not a regular file'
        return 1
      fi
      mkdir -p -- "$dest/$(dirname -- "$key")"
      cp -p -- "$work/out/$top/$key" "$dest/$key"
    done <"$work/present"
  fi
}

# ceo_load_pristine <tag> <dest-dir> <keyfile> <pristine-dir or empty>
ceo_load_pristine() {
  local archive
  mkdir -p -- "$2"
  if [[ -n $4 ]]; then
    ceo_stage_pristine_dir "$4" "$2" "$3"
    return
  fi
  archive="$(ceo_scratch_dir dl)/archive.tar.gz"
  ceo_download "$1" "$archive" || return $?
  ceo_extract_archive "$archive" "$2" "$3"
}

# --- checks on a staged pristine tree and on the patched result --------------

# ceo_check_preimages <base.json> <keyfile> <pristine-dir>
ceo_check_preimages() {
  local base=$1 keyfile=$2 pristine=$3 key pre_sha pre_mode status=0
  while IFS= read -r key; do
    pre_sha=$(ceo_base_field "$base" "$key" '.preimage | if . == "absent" then "absent" else .sha256 end')
    if [[ $pre_sha == absent ]]; then
      if [[ -e $pristine/$key ]]; then
        ceo_report collision "$key" 'upstream now ships a file at a path this overlay creates'
        status=1
      fi
      continue
    fi
    if [[ ! -f $pristine/$key ]]; then
      ceo_report removed-upstream "$key" 'upstream no longer ships this patched file'
      status=1
      continue
    fi
    pre_mode=$(ceo_base_field "$base" "$key" .preimage.mode)
    if [[ $(ceo_sha256 "$pristine/$key") != "$pre_sha" ]]; then
      ceo_report preimage-mismatch "$key" 'upstream file content differs from the recorded pre-image sha256'
      status=1
    elif [[ $(ceo_mode "$pristine/$key") != "$pre_mode" ]]; then
      ceo_report preimage-mismatch "$key" "upstream file mode differs from the recorded pre-image mode $pre_mode"
      status=1
    fi
  done <"$keyfile"
  return "$status"
}

# ceo_check_postimages <base.json> <keyfile> <applied-dir>
ceo_check_postimages() {
  local base=$1 keyfile=$2 applied=$3 key status=0
  while IFS= read -r key; do
    if [[ $(ceo_sha256 "$applied/$key") != "$(ceo_base_field "$base" "$key" .postimage.sha256)" ]]; then
      ceo_report postimage-mismatch "$key" 'patched sha256 differs from the recorded post-image'
      status=1
    elif [[ $(ceo_mode "$applied/$key") != "$(ceo_base_field "$base" "$key" .mode)" ]]; then
      ceo_report postimage-mismatch "$key" 'patched mode differs from the recorded mode'
      status=1
    fi
  done <"$keyfile"
  return "$status"
}

# ceo_authoring_effort <repo-root>
# The roster's Claude authoring effort, rendered through render() with the stub
# `op` contract in AGENTS.md.
ceo_authoring_effort() {
  local repo_root=$1 dir chezmoi_bin
  chezmoi_bin=$(command -v chezmoi) || return 127
  dir=$(ceo_scratch_dir render)
  mkdir -p -- "$dir/bin" "$dir/home" "$dir/target"
  printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' >"$dir/bin/op"
  chmod 700 "$dir/bin/op"
  : >"$dir/empty.toml"
  printf '%s' '{{ (includeTemplate "agent-roster-lookup.tmpl" (dict "roster" .agents.roster "agent" "claude" "shape" "authoring" "rung" "" "name" "a claude authoring entry") | fromJson).effort }}' >"$dir/effort.tmpl"
  render "$repo_root" "$dir" "$chezmoi_bin" linux "$dir/effort.tmpl" "$dir/effort.out" || return 1
  [[ -s $dir/effort.out ]] || return 1
  cat -- "$dir/effort.out"
}

ceo_check_persona() { # <file>
  local needle status=0
  for needle in "${CEO_PERSONA_STRINGS[@]}"; do
    if ! grep -qF -- "$needle" "$1"; then
      ceo_report contract "$CEO_PERSONA_KEY" "persona missing: $needle"
      status=1
    fi
  done
  if grep -qiE '\bgh\b|github-cli' "$1"; then
    ceo_report contract "$CEO_PERSONA_KEY" 'persona references gh/github-cli tooling'
    status=1
  fi
  if grep -qiE 'glab mr\b|glab mr list|merge request list' "$1"; then
    ceo_report contract "$CEO_PERSONA_KEY" 'persona fetches merge requests'
    status=1
  fi
  return "$status"
}

ceo_check_interview() { # <file>
  local needle status=0
  for needle in "${CEO_INTERVIEW_STRINGS[@]}"; do
    if ! grep -qF -- "$needle" "$1"; then
      ceo_report contract "$CEO_INTERVIEW_KEY" "interview missing: $needle"
      status=1
    fi
  done
  return "$status"
}

ceo_check_effort() { # <file> <key> <effort>
  local line
  line=$(grep -oE '^EFFORT="[^"]*"' "$1" | head -n1 || true)
  if [[ $line != "EFFORT=\"$3\"" ]]; then
    ceo_report contract "$2" "adapter assigns ${line:-no EFFORT}; the roster authoring effort is $3"
    return 1
  fi
}

# ceo_check_contracts <applied-dir> <keyfile> <authoring-effort>
# The persona, interview, and effort contracts run on the patched result. All
# four contract paths must be patched, so dropping one cannot pass silently.
ceo_check_contracts() {
  local applied=$1 keyfile=$2 effort=$3 key status=0
  for key in "$CEO_PERSONA_KEY" "$CEO_INTERVIEW_KEY" $CEO_ADAPTER_KEYS; do
    if ! grep -qxF -- "$key" "$keyfile"; then
      ceo_report contract "$key" 'base.json has no entry for a path with a content contract'
      status=1
    fi
  done
  [[ $status == 0 ]] || return 1
  ceo_check_persona "$applied/$CEO_PERSONA_KEY" || status=1
  ceo_check_interview "$applied/$CEO_INTERVIEW_KEY" || status=1
  for key in $CEO_ADAPTER_KEYS; do
    ceo_check_effort "$applied/$key" "$key" "$effort" || status=1
  done
  return "$status"
}
