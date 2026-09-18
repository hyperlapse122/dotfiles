#!/usr/bin/env bash
set -euo pipefail

# Offline verification of the compound-engineering overlay patch tooling:
# .ci/lib/ce-overlay.sh, the upstream gate .ci/check-ce-overlay-patches.sh, and
# the rebase driver .ci/ce-overlay-rebase.sh.
#
# Every scenario runs against fixture trees under .ci/fixtures/ce-overlays and a
# scratch overlay directory that the driver seeds itself. Upstream arrives
# through --pristine-dir, or through a stub `curl` that serves a tarball built
# here; nothing reaches the network.
#
# GATE. Each class and exit status: valid, preimage-mismatch, collision,
# removed-upstream, unavailable (never 1), version-mismatch against the pin and
# candidate mode, coverage (second path, rename, `..`, missing or stray patch,
# and the switchable overlay-directory check), contract (persona, effort),
# postimage-mismatch (sha256 and mode), a pre-image mode difference, a malformed
# tag, a lock source outside the allowlist with no request made, and hostile
# archive members. A hostile global git config and an enclosing repository do
# not change the result.
# DRIVER. prepare routes unchanged, apply, 3way, conflict, collision, and
# removed-upstream with the KTD7 exit statuses and leaves the overlay untouched;
# finish refuses conflict markers, is byte-stable, and reports whether the
# customization lines changed; stamp moves only the tag and refuses on any
# pre-image difference; seed refuses to overwrite an existing base.json.

root=${1:-$(pwd)}
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/ce-overlay-tooling.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

# shellcheck source=.ci/lib/ce-overlay.sh
source "$root/.ci/lib/ce-overlay.sh"
CEO_SCRATCH=$scratch
CEO_REPORT="$scratch/report"
: >"$CEO_REPORT"
ceo_git_prepare "$scratch/git-home"

gate="$root/.ci/check-ce-overlay-patches.sh"
driver="$root/.ci/ce-overlay-rebase.sh"
fx="$root/.ci/fixtures/ce-overlays"

fail() {
  printf 'test-ce-overlay-tooling: %s\n' "$*" >&2
  exit 1
}

pass() { printf 'test-ce-overlay-tooling: ok - %s\n' "$*"; }

command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is required for the effort contract'

tag_old=compound-engineering-v3.26.3
tag_new=compound-engineering-v3.26.4
k_int=skills/ce-sweep/references/interview.md
k_persona=skills/ce-sweep/references/sources/gitlab-issues.md
k_plan=skills/ce-plan/scripts/elevation-dispatch.sh
k_brain=skills/ce-brainstorm/scripts/elevation-dispatch.sh
keys=("$k_int" "$k_persona" "$k_plan" "$k_brain")

effort=$(ceo_authoring_effort "$root") || fail 'could not render the roster authoring effort'

# --- fixtures ----------------------------------------------------------------

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

edit_line() { # <file> <line> <text>
  awk -v n="$2" -v text="$3" 'NR == n { print text; next } { print }' "$1" >"$1.tmp"
  mv -- "$1.tmp" "$1"
}

insert_after() { # <file> <line> <text>
  awk -v n="$2" -v text="$3" '{ print } NR == n { print text }' "$1" >"$1.tmp"
  mv -- "$1.tmp" "$1"
}

snapshot() { # <dir>
  local file
  while IFS= read -r file; do
    printf '%s %s\n' "$file" "$(ceo_sha256 "$1/$file")"
  done < <(cd -- "$1" && find . -type f | sort)
}

old="$scratch/upstream-old"
post="$scratch/postimage"
materialize upstream-old "$old"
materialize postimage "$post"

write_lock() { # <file> <source> <version>
  jq -n --arg source "$2" --arg version "$3" \
    '{releases: {tools: {"compound-engineering": {kind: "githubRelease", source: $source, version: $version}}}}' >"$1"
}

source_allowed=everyinc/compound-engineering-plugin
lock_old="$scratch/lock-old.json"
lock_new="$scratch/lock-new.json"
write_lock "$lock_old" "$source_allowed" "$tag_old"
write_lock "$lock_new" "$source_allowed" "$tag_new"

rc=0
out=''
err=''
run() {
  rc=0
  out=$("$@" 2>"$scratch/stderr") || rc=$?
  err=$(<"$scratch/stderr")
}

seed_overlay() { # <overlay-dir> <post-tree> <pristine-tree> <tag>
  local key
  local -a posts=()
  for key in "${keys[@]}"; do posts+=(--post "$key=$2/$key"); done
  run "$driver" seed --overlay-dir "$1" --lock "$lock_old" --pristine-dir "$3" --target-tag "$4" "${posts[@]}"
  [[ $rc == 0 ]] || fail "seed failed ($rc): $err"
}

ov="$scratch/overlay"
seed_overlay "$ov" "$post" "$old" "$tag_old"

fresh_overlay() { # <name> -> path of a copy of the seeded overlay
  cp -Rp -- "$ov" "$scratch/$1"
  printf '%s' "$scratch/$1"
}

variant() { # <name> -> path of a copy of the old upstream tree
  cp -Rp -- "$old" "$scratch/$1"
  printf '%s' "$scratch/$1"
}

expect_gate() { # <label> <status> <class> <gate arguments...>
  local label=$1 want_rc=$2 want_class=$3
  shift 3
  run "$gate" "$@"
  [[ $rc == "$want_rc" ]] || fail "$label: status $rc, want $want_rc: $err"
  printf '%s\n' "$out" | grep -qxF "class=$want_class" || fail "$label: stdout lacks class=$want_class: $out / $err"
  pass "gate $label"
}

gate_args=(--overlay-dir "$ov" --lock "$lock_old" --pristine-dir "$old")

# --- seeded fixture overlay --------------------------------------------------

[[ $(jq -r '.version' "$ov/base.json") == "$tag_old" ]] || fail 'seed did not record the tag'
[[ $(jq -r --arg k "$k_persona" '.paths[$k].preimage' "$ov/base.json") == absent ]] || fail 'seed did not record an absent pre-image'
[[ $(jq -r --arg k "$k_plan" '.paths[$k].mode' "$ov/base.json") == 0755 ]] || fail 'seed did not record the adapter mode'
[[ $(jq -r --arg k "$k_plan" '.paths[$k].preimage.mode' "$ov/base.json") == 0755 ]] || fail 'seed did not record the adapter pre-image mode'
run "$driver" seed --overlay-dir "$ov" --lock "$lock_old" --pristine-dir "$old" --target-tag "$tag_old" --post "$k_int=$post/$k_int"
[[ $rc == 64 ]] || fail "seed over an existing base.json returned $rc, want 64"
pass 'seed refuses to overwrite base.json'

# --- gate: statuses and classes ----------------------------------------------

expect_gate 'valid overlay validates against its own upstream' 0 valid "${gate_args[@]}"

changed=$(variant up-changed)
insert_after "$changed/$k_int" 1 'An upstream edit that moves the recorded pre-image.'
expect_gate 'a changed patched file is a preimage-mismatch' 1 preimage-mismatch \
  --overlay-dir "$ov" --lock "$lock_old" --pristine-dir "$changed"

shipped=$(variant up-collision)
mkdir -p -- "$shipped/$(dirname -- "$k_persona")"
printf 'upstream persona\n' >"$shipped/$k_persona"
expect_gate 'upstream shipping the absent path is a collision' 1 collision \
  --overlay-dir "$ov" --lock "$lock_old" --pristine-dir "$shipped"

removed=$(variant up-removed)
rm -- "$removed/$k_brain"
expect_gate 'a missing patched file is removed-upstream' 1 removed-upstream \
  --overlay-dir "$ov" --lock "$lock_old" --pristine-dir "$removed"

moded=$(variant up-mode)
chmod 0755 "$moded/$k_int"
expect_gate 'equal bytes with a different pre-image mode are a preimage-mismatch' 1 preimage-mismatch \
  --overlay-dir "$ov" --lock "$lock_old" --pristine-dir "$moded"

expect_gate 'pinned mode with a base.json tag that differs from the pin' 1 version-mismatch \
  --overlay-dir "$ov" --lock "$lock_new" --pristine-dir "$old"
expect_gate 'candidate mode does not fail on the tag' 0 valid \
  --overlay-dir "$ov" --lock "$lock_new" --pristine-dir "$old" --candidate-tag "$tag_new"

for bad_tag in v3.26.4 compound-engineering-v3.26 compound-engineering-v3.26.4/../x 'compound-engineering-v3.26.4 '; do
  expect_gate "candidate tag '$bad_tag' is refused" 1 schema \
    --overlay-dir "$ov" --lock "$lock_old" --pristine-dir "$old" --candidate-tag "$bad_tag"
done

# coverage: patch headers, layout, and the switchable directory check
cov=$(fresh_overlay cov-second)
cat -- "$cov/patches/$k_plan.patch" >>"$cov/patches/$k_int.patch"
expect_gate 'a patch that names a second path' 1 coverage --overlay-dir "$cov" --lock "$lock_old" --pristine-dir "$old"

cov=$(fresh_overlay cov-rename)
printf 'diff --git a/%s b/skills/moved.md\nsimilarity index 100%%\nrename from %s\nrename to skills/moved.md\n' "$k_int" "$k_int" >"$cov/patches/$k_int.patch"
expect_gate 'a patch that renames' 1 coverage --overlay-dir "$cov" --lock "$lock_old" --pristine-dir "$old"

cov=$(fresh_overlay cov-dotdot)
printf 'diff --git a/../evil b/../evil\n--- a/../evil\n+++ b/../evil\n@@ -1 +1 @@\n-a\n+b\n' >"$cov/patches/$k_int.patch"
expect_gate 'a patch with a ".." segment' 1 coverage --overlay-dir "$cov" --lock "$lock_old" --pristine-dir "$old"

cov=$(fresh_overlay cov-missing)
rm -- "$cov/patches/$k_plan.patch"
expect_gate 'a base.json key without a patch' 1 coverage --overlay-dir "$cov" --lock "$lock_old" --pristine-dir "$old"

cov=$(fresh_overlay cov-extra-patch)
cp -- "$cov/patches/$k_plan.patch" "$cov/patches/skills/ce-plan/scripts/other.sh.patch"
expect_gate 'a patch without a base.json key' 1 coverage --overlay-dir "$cov" --lock "$lock_old" --pristine-dir "$old"

cov=$(fresh_overlay cov-legacy)
mkdir -p -- "$cov/skills/ce-plan/scripts"
printf 'legacy\n' >"$cov/skills/ce-plan/scripts/executable_elevation-dispatch.sh"
expect_gate 'a whole-file copy beside the patches' 1 coverage --overlay-dir "$cov" --lock "$lock_old" --pristine-dir "$old"
expect_gate 'the same tree with the legacy switch' 0 valid \
  --overlay-dir "$cov" --lock "$lock_old" --pristine-dir "$old" --allow-legacy-overlay-files
cov=$(fresh_overlay cov-symlink)
ln -s -- "$cov/base.json" "$cov/patches/skills/link.patch"
expect_gate 'a symlink under patches stays refused with the legacy switch' 1 coverage \
  --overlay-dir "$cov" --lock "$lock_old" --pristine-dir "$old" --allow-legacy-overlay-files

# contracts run on the patched result
bad_post="$scratch/post-no-glab"
cp -Rp -- "$post" "$bad_post"
persona_text=$(<"$bad_post/$k_persona")
printf '%s\n' "${persona_text//glab/gl}" >"$bad_post/$k_persona"
seed_overlay "$scratch/ov-no-glab" "$bad_post" "$old" "$tag_old"
expect_gate 'a persona without glab' 1 contract \
  --overlay-dir "$scratch/ov-no-glab" --lock "$lock_old" --pristine-dir "$old"

bad_post="$scratch/post-effort"
cp -Rp -- "$post" "$bad_post"
edit_line "$bad_post/$k_plan" 7 'EFFORT="bogus"'
grep -q '^EFFORT="bogus"$' "$bad_post/$k_plan" || fail 'fixture line for the effort edit moved'
seed_overlay "$scratch/ov-effort" "$bad_post" "$old" "$tag_old"
expect_gate 'an adapter effort that differs from the roster' 1 contract \
  --overlay-dir "$scratch/ov-effort" --lock "$lock_old" --pristine-dir "$old"

bad_post="$scratch/post-no-interview-marker"
cp -Rp -- "$post" "$bad_post"
interview_text=$(<"$bad_post/$k_int")
printf '%s\n' "${interview_text//feedback:resolved/x}" >"$bad_post/$k_int"
seed_overlay "$scratch/ov-interview" "$bad_post" "$old" "$tag_old"
expect_gate 'an interview without the resolved label' 1 contract \
  --overlay-dir "$scratch/ov-interview" --lock "$lock_old" --pristine-dir "$old"

# recorded post-image
rec=$(fresh_overlay rec-sha)
jq --arg k "$k_int" '.paths[$k].postimage.sha256 = ("0" * 64)' "$rec/base.json" >"$rec/base.json.new"
mv -- "$rec/base.json.new" "$rec/base.json"
expect_gate 'a recorded post-image sha256 that differs' 1 postimage-mismatch \
  --overlay-dir "$rec" --lock "$lock_old" --pristine-dir "$old"
rec=$(fresh_overlay rec-mode)
jq --arg k "$k_int" '.paths[$k].mode = "0755"' "$rec/base.json" >"$rec/base.json.new"
mv -- "$rec/base.json.new" "$rec/base.json"
expect_gate 'a recorded mode that differs' 1 postimage-mismatch \
  --overlay-dir "$rec" --lock "$lock_old" --pristine-dir "$old"

sch=$(fresh_overlay sch-key)
jq '.paths["../evil"] = .paths["skills/ce-plan/scripts/elevation-dispatch.sh"]' "$sch/base.json" >"$sch/base.json.new"
mv -- "$sch/base.json.new" "$sch/base.json"
expect_gate 'a base.json key with a ".." segment' 1 schema --overlay-dir "$sch" --lock "$lock_old" --pristine-dir "$old"
sch=$(fresh_overlay sch-shape)
jq 'del(.paths[].postimage)' "$sch/base.json" >"$sch/base.json.new"
mv -- "$sch/base.json.new" "$sch/base.json"
expect_gate 'a base.json entry without a post-image' 1 schema --overlay-dir "$sch" --lock "$lock_old" --pristine-dir "$old"

# hostile ambient state does not change the result
hostile="$scratch/hostile-home"
mkdir -p -- "$hostile"
printf '[core]\n\tautocrlf = true\n\twhitespace = trailing-space\n[apply]\n\twhitespace = error\n[diff]\n\tnoprefix = true\n[init]\n\tdefaultBranch = other\n' >"$hostile/gitconfig"
run env HOME="$hostile" GIT_CONFIG_GLOBAL="$hostile/gitconfig" "$gate" "${gate_args[@]}"
[[ $rc == 0 ]] || fail "a hostile git configuration changed the result: $err"
mkdir -p -- "$scratch/enclosing"
ceo_git init -q -- "$scratch/enclosing" >/dev/null
run env RUNNER_TEMP="$scratch/enclosing" "$gate" "${gate_args[@]}"
[[ $rc == 0 ]] || fail "an enclosing repository changed the result: $err"
pass 'gate ignores user git configuration and enclosing repositories'

# --- gate: download path through a stub curl ---------------------------------

stub_bin="$scratch/stub-bin"
mkdir -p -- "$stub_bin"
cat >"$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_CURL_LOG"
[ "${STUB_CURL_MODE:-serve}" = fail ] && exit 7
out=''
while [ $# -gt 0 ]; do
  if [ "$1" = --output ]; then out=$2; shift; fi
  shift
done
cp -- "$STUB_CURL_ARCHIVE" "$out"
STUB
chmod 0755 "$stub_bin/curl"
curl_log="$scratch/curl.log"
top="compound-engineering-plugin-$tag_old"

pack() { # <stage directory holding $top> <archive>
  (
    cd -- "$1"
    find "$top" | sort >"$scratch/pack.list"
    tar -czf "$2" --no-recursion -T "$scratch/pack.list"
  )
}

make_archive() { # <tree> <archive>: packs the tree under the release's top directory
  local stage="$scratch/archive-stage"
  rm -rf -- "$stage"
  mkdir -p -- "$stage"
  cp -Rp -- "$1" "$stage/$top"
  pack "$stage" "$2"
}

net_gate() { # <mode> <archive> <gate arguments...>
  local mode=$1 archive=$2
  shift 2
  : >"$curl_log"
  run env PATH="$stub_bin:$PATH" STUB_CURL_MODE="$mode" STUB_CURL_ARCHIVE="$archive" STUB_CURL_LOG="$curl_log" \
    CE_OVERLAY_FETCH_RETRY_DELAY=0 "$gate" "$@"
}

expected_url="https://github.com/$source_allowed/archive/refs/tags/$tag_old.tar.gz"
archive_ok="$scratch/ok.tgz"
make_archive "$old" "$archive_ok"

net_gate serve "$archive_ok" --overlay-dir "$ov" --lock "$lock_old"
[[ $rc == 0 ]] || fail "download path: status $rc: $err"
grep -qF -- "$expected_url" "$curl_log" || fail "download path requested an unexpected URL: $(cat "$curl_log")"
pass 'gate downloads the pinned tag from the fixed host and validates it'

lock_mixed="$scratch/lock-mixed.json"
write_lock "$lock_mixed" EveryInc/Compound-Engineering-Plugin "$tag_old"
net_gate serve "$archive_ok" --overlay-dir "$ov" --lock "$lock_mixed"
[[ $rc == 0 ]] || fail "a mixed-case allowlisted source was refused: $err"
grep -qF -- "$expected_url" "$curl_log" || fail 'a mixed-case source changed the URL'
pass 'gate accepts the allowlisted source case-insensitively'

: >"$curl_log"
run env PATH="$stub_bin:$PATH" STUB_CURL_MODE=serve STUB_CURL_ARCHIVE="$archive_ok" STUB_CURL_LOG="$curl_log" \
  GITHUB_TOKEN=ghs_fixturetoken CE_OVERLAY_FETCH_RETRY_DELAY=0 "$gate" --overlay-dir "$ov" --lock "$lock_old"
[[ $rc == 0 ]] || fail "download with a token: status $rc: $err"
grep -q -- '--header @' "$curl_log" || fail 'the token was not sent through a header file'
if grep -qF ghs_fixturetoken "$curl_log"; then fail 'the token appeared in curl arguments'; fi
pass 'gate sends GITHUB_TOKEN through a header file, never in argv'

net_gate fail "$archive_ok" --overlay-dir "$ov" --lock "$lock_old"
[[ $rc == 2 ]] || fail "an unreachable archive returned $rc, want 2: $err"
printf '%s\n' "$out" | grep -qxF 'class=unavailable' || fail "unreachable archive: no class=unavailable: $out"
[[ $(wc -l <"$curl_log" | tr -d ' ') == 3 ]] || fail 'the download did not make three bounded attempts'
pass 'gate reports an unreachable archive as unavailable after three attempts'

printf 'not a tarball\n' >"$scratch/garbage.tgz"
net_gate serve "$scratch/garbage.tgz" --overlay-dir "$ov" --lock "$lock_old"
[[ $rc == 2 ]] || fail "a corrupt archive returned $rc, want 2: $err"
pass 'gate reports a corrupt archive as unavailable'

for bad_source in evil/compound-engineering-plugin everyinc/other-repo gitlab.com/everyinc/compound-engineering-plugin \
  'everyinc/compound-engineering-plugin/extra' 'http://evil.example/x'; do
  lock_bad="$scratch/lock-bad.json"
  write_lock "$lock_bad" "$bad_source" "$tag_old"
  net_gate serve "$archive_ok" --overlay-dir "$ov" --lock "$lock_bad"
  [[ $rc == 1 ]] || fail "source '$bad_source' returned $rc, want 1"
  printf '%s\n' "$out" | grep -qxF 'class=schema' || fail "source '$bad_source': no class=schema: $out"
  [[ ! -s $curl_log ]] || fail "source '$bad_source' made a request"
done
pass 'gate refuses a lock source outside the allowlist before any request'

net_gate serve "$archive_ok" --overlay-dir "$ov" --lock "$lock_old" --candidate-tag compound-engineering-v3.26.4.5
[[ $rc == 1 && ! -s $curl_log ]] || fail 'a malformed candidate tag reached the network'

# hostile archive members
outside="$scratch/outside"
mkdir -p -- "$outside"
printf 'keep\n' >"$outside/target"

hostile_tree=$(variant hostile-symlink)
rm -- "$hostile_tree/$k_int"
ln -s -- "$outside/target" "$hostile_tree/$k_int"
make_archive "$hostile_tree" "$scratch/symlink.tgz"
net_gate serve "$scratch/symlink.tgz" --overlay-dir "$ov" --lock "$lock_old"
[[ $rc == 1 ]] || fail "a symlink member returned $rc, want 1: $err"
printf '%s\n' "$out" | grep -qxF 'class=schema' || fail "a symlink member: no class=schema: $out"

rm -rf -- "$scratch/archive-stage"
mkdir -p -- "$scratch/archive-stage"
cp -Rp -- "$old" "$scratch/archive-stage/$top"
printf 'first\n' >"$scratch/archive-stage/$top/aaa-first"
rm -- "$scratch/archive-stage/$top/$k_int"
ln -- "$scratch/archive-stage/$top/aaa-first" "$scratch/archive-stage/$top/$k_int"
pack "$scratch/archive-stage" "$scratch/hardlink.tgz"
net_gate serve "$scratch/hardlink.tgz" --overlay-dir "$ov" --lock "$lock_old"
[[ $rc == 1 ]] || fail "a hardlink member returned $rc, want 1: $err"
printf '%s\n' "$out" | grep -qxF 'class=schema' || fail "a hardlink member: no class=schema: $out"

hostile_stage="$scratch/dotdot-stage"
mkdir -p -- "$hostile_stage/$top/skills/ce-sweep/references"
printf 'x\n' >"$hostile_stage/$top/skills/ce-sweep/references/interview.md"
tar -czPf "$scratch/dotdot.tgz" -C "$hostile_stage" "$top/skills/ce-sweep/references/../references/interview.md"
net_gate serve "$scratch/dotdot.tgz" --overlay-dir "$ov" --lock "$lock_old"
[[ $rc == 1 ]] || fail "a '..' member returned $rc, want 1: $err"
printf '%s\n' "$out" | grep -qxF 'class=schema' || fail "a '..' member: no class=schema: $out"

rm -rf -- "$scratch/archive-stage" "$scratch/archive-link"
mkdir -p -- "$scratch/archive-stage/$top/skills" "$scratch/archive-link/$top/skills/ce-sweep/references"
ln -s -- "$outside" "$scratch/archive-stage/$top/skills/ce-sweep"
cp -- "$old/$k_int" "$scratch/archive-link/$top/$k_int"
tar -cf "$scratch/parent-link.tar" -C "$scratch/archive-stage" "$top/skills/ce-sweep"
tar -rf "$scratch/parent-link.tar" -C "$scratch/archive-link" "$top/$k_int"
gzip -f -- "$scratch/parent-link.tar"
net_gate serve "$scratch/parent-link.tar.gz" --overlay-dir "$ov" --lock "$lock_old"
[[ $rc == 1 ]] || fail "a symlinked parent directory returned $rc, want 1: $err"
printf '%s\n' "$out" | grep -qxF 'class=schema' || fail "a symlinked parent directory: no class=schema: $out"

[[ $(<"$outside/target") == keep ]] || fail 'a hostile archive changed a file outside the scratch directory'
[[ $(find "$outside" -type f | wc -l | tr -d ' ') == 1 ]] || fail 'a hostile archive wrote beside the outside file'
pass 'gate treats symlink, hardlink, ".." members, and symlinked parents as schema failures and writes nothing outside scratch'

# --- driver: prepare routing -------------------------------------------------

work_n=0
prepare() { # <overlay> <new-tree> [extra arguments] : sets $work
  local overlay=$1 new=$2
  shift 2
  work_n=$((work_n + 1))
  work="$scratch/work-$work_n"
  run "$driver" prepare --overlay-dir "$overlay" --lock "$lock_old" --work-dir "$work" \
    --old-pristine-dir "$old" --pristine-dir "$new" --target-tag "$tag_new" "$@"
}

expect_route() { # <key> <route>
  printf '%s\n' "$out" | grep -qxF "route=$2 path=$1" || fail "expected route=$2 for $1, got: $out"
}

before=$(snapshot "$ov")

prepare "$ov" "$old"
[[ $rc == 0 ]] || fail "prepare on unchanged pre-images returned $rc: $err"
for key in "${keys[@]}"; do expect_route "$key" unchanged; done
printf '%s\n' "$out" | grep -qxF 'result=resolved' || fail "prepare did not report result=resolved: $out"
[[ $(snapshot "$ov") == "$before" ]] || fail 'prepare wrote into the overlay directory'
pass 'prepare reports unchanged for every path and leaves the overlay untouched'

work_unchanged=$work
ovf=$(fresh_overlay finish-unchanged)
run "$driver" finish --overlay-dir "$ovf" --work-dir "$work_unchanged"
[[ $rc == 0 ]] || fail "finish on unchanged paths returned $rc: $err"
[[ $(jq -r '.version' "$ovf/base.json") == "$tag_new" ]] || fail 'finish did not stamp the target tag'
diff -r --exclude=base.json "$ov" "$ovf" >/dev/null || fail 'finish on unchanged paths rewrote a patch'
[[ $(jq -S 'del(.version)' "$ov/base.json") == "$(jq -S 'del(.version)' "$ovf/base.json")" ]] || fail 'finish on unchanged paths changed more than the tag'
printf '%s\n' "$out" | grep -qxF 'customization=unchanged' || fail "finish did not report unchanged: $out"
snap_first=$(snapshot "$ovf")
run "$driver" finish --overlay-dir "$ovf" --work-dir "$work_unchanged"
[[ $rc == 0 && $(snapshot "$ovf") == "$snap_first" ]] || fail 'finish is not byte-stable on a second run'
pass 'finish on unchanged paths changes only the tag and is byte-stable'

up_apply=$(variant up-apply)
edit_line "$up_apply/$k_int" 1 '# Sweep interview (revised)'
edit_line "$up_apply/$k_int" 22 'The interview ends when the user confirms the config.'
prepare "$ov" "$up_apply"
[[ $rc == 0 ]] || fail "prepare on a distant upstream edit returned $rc: $err"
expect_route "$k_int" apply
expect_route "$k_persona" unchanged
expect_route "$k_plan" unchanged
[[ $(snapshot "$ov") == "$before" ]] || fail 'prepare wrote into the overlay directory'
work_apply=$work
ovf=$(fresh_overlay finish-apply)
run "$driver" finish --overlay-dir "$ovf" --work-dir "$work_apply"
[[ $rc == 0 ]] || fail "finish after apply returned $rc: $err"
printf '%s\n' "$out" | grep -qxF 'customization=unchanged' || fail "a context-only move was not reported as unchanged: $out"
printf '%s\n' "$out" | grep -qxF "path=$k_int customization=unchanged" || fail "no per-path report for $k_int: $out"
run "$gate" --overlay-dir "$ovf" --lock "$lock_new" --pristine-dir "$up_apply" --candidate-tag "$tag_new"
[[ $rc == 0 ]] || fail "the regenerated overlay is not valid against the new upstream: $err"
pass 'an edit away from our hunks routes apply and reports customization unchanged'

up_3way=$(variant up-3way)
edit_line "$up_3way/$k_int" 15 'Ask which labels mark acknowledged and resolved items. Suggested defaults:'
prepare "$ov" "$up_3way"
[[ $rc == 0 ]] || fail "prepare on a context edit returned $rc: $err"
expect_route "$k_int" 3way
work_3way=$work
ovf=$(fresh_overlay finish-3way)
run "$driver" finish --overlay-dir "$ovf" --work-dir "$work_3way"
[[ $rc == 0 ]] || fail "finish after 3way returned $rc: $err"
printf '%s\n' "$out" | grep -qxF 'customization=unchanged' || fail "a three-way result was not reported as unchanged: $out"
grep -qF 'Suggested defaults' "$work_3way/files/$k_int" || fail 'the three-way result lost the upstream edit'
grep -qF 'feedback:ack' "$work_3way/files/$k_int" || fail 'the three-way result lost our lines'
pass 'an edit that needs the old blob routes 3way'

up_conflict=$(variant up-conflict)
insert_after "$up_conflict/$k_int" 13 '- `teams` takes a channel id.'
prepare "$ov" "$up_conflict"
[[ $rc == 3 ]] || fail "prepare on a conflicting edit returned $rc, want 3: $err"
expect_route "$k_int" conflict
printf '%s\n' "$out" | grep -qxF 'result=claude' || fail "no result=claude: $out"
[[ $(snapshot "$ov") == "$before" ]] || fail 'a conflicting prepare wrote into the overlay directory'
grep -qE '^<<<<<<< upstream$' "$work/files/$k_int" || fail 'the conflict markers do not name the upstream side'
grep -qE '^>>>>>>> customization$' "$work/files/$k_int" || fail 'the conflict markers do not name the customization side'
[[ $(jq -r '.conflicted | join(",")' "$work/manifest.json") == "$k_int" ]] || fail 'the manifest does not list the conflicted path'
[[ $(jq -r --arg k "$k_int" '.paths[$k].sha256' "$work/manifest.json") == "$(ceo_sha256 "$work/files/$k_int")" ]] || fail 'the manifest sha256 does not match the work file'
work_conflict=$work
ovf=$(fresh_overlay finish-conflict)
snap_first=$(snapshot "$ovf")
run "$driver" finish --overlay-dir "$ovf" --work-dir "$work_conflict"
[[ $rc == 1 ]] || fail "finish with unresolved markers returned $rc, want 1"
[[ $(snapshot "$ovf") == "$snap_first" ]] || fail 'finish with unresolved markers wrote into the overlay directory'
pass 'a conflicting edit routes conflict, exits 3, and finish refuses unresolved markers'

resolve_conflict() { # <work-dir> <extra line for our second entry>
  cp -- "$up_conflict/$k_int" "$1/files/$k_int"
  insert_after "$1/files/$k_int" 14 '- `gitlab-issues` takes a `group/project` target.'
  insert_after "$1/files/$k_int" 15 "$2"
}
resolve_conflict "$work_conflict" '- `gitlab-issues` marks items with the labels `feedback:ack` and `feedback:resolved`.'
run "$driver" finish --overlay-dir "$ovf" --work-dir "$work_conflict"
[[ $rc == 0 ]] || fail "finish after resolving returned $rc: $err"
printf '%s\n' "$out" | grep -qxF 'customization=unchanged' || fail "a resolution that keeps our lines was not reported as unchanged: $out"
run "$gate" --overlay-dir "$ovf" --lock "$lock_new" --pristine-dir "$up_conflict" --candidate-tag "$tag_new"
[[ $rc == 0 ]] || fail "the resolved overlay is not valid: $err"

prepare "$ov" "$up_conflict"
resolve_conflict "$work" '- `gitlab-issues` marks items with `feedback:ack` and `feedback:resolved` only.'
ovf=$(fresh_overlay finish-conflict-changed)
run "$driver" finish --overlay-dir "$ovf" --work-dir "$work"
[[ $rc == 0 ]] || fail "finish after a changed resolution returned $rc: $err"
printf '%s\n' "$out" | grep -qxF 'customization=changed' || fail "a changed customization line was not reported: $out"
printf '%s\n' "$out" | grep -qxF "path=$k_int customization=changed" || fail "no per-path changed report: $out"
pass 'finish reports customization unchanged or changed from the added and removed lines'

up_collision=$(variant up-collision-driver)
mkdir -p -- "$up_collision/$(dirname -- "$k_persona")"
printf '# Upstream GitLab source\nUpstream ships its own source.\n' >"$up_collision/$k_persona"
prepare "$ov" "$up_collision"
[[ $rc == 3 ]] || fail "prepare on a collision returned $rc, want 3: $err"
expect_route "$k_persona" collision
grep -qE '^<<<<<<< upstream$' "$work/files/$k_persona" || fail 'the collision work file has no conflict markers'
[[ $(snapshot "$ov") == "$before" ]] || fail 'a collision prepare wrote into the overlay directory'
cp -- "$post/$k_persona" "$work/files/$k_persona"
ovf=$(fresh_overlay finish-collision)
run "$driver" finish --overlay-dir "$ovf" --work-dir "$work"
[[ $rc == 0 ]] || fail "finish after a collision resolution returned $rc: $err"
[[ $(jq -r --arg k "$k_persona" '.paths[$k].preimage | type' "$ovf/base.json") == object ]] || fail 'a resolved collision still records an absent pre-image'
printf '%s\n' "$out" | grep -qxF 'customization=changed' || fail "a resolved collision was not reported as changed: $out"
run "$gate" --overlay-dir "$ovf" --lock "$lock_new" --pristine-dir "$up_collision" --candidate-tag "$tag_new"
[[ $rc == 0 ]] || fail "the collision-resolved overlay is not valid: $err"
pass 'a collision routes to Claude and resolves into a real pre-image'

up_removed=$(variant up-removed-driver)
rm -- "$up_removed/$k_brain"
prepare "$ov" "$up_removed"
[[ $rc == 4 ]] || fail "prepare on a removed file returned $rc, want 4: $err"
expect_route "$k_brain" removed-upstream
printf '%s\n' "$out" | grep -qxF 'result=genuine' || fail "no result=genuine: $out"
ovf=$(fresh_overlay finish-removed)
run "$driver" finish --overlay-dir "$ovf" --work-dir "$work"
[[ $rc == 1 ]] || fail "finish after removed-upstream returned $rc, want 1"
pass 'a patched path that upstream removed exits 4 and finish refuses it'

up_recorded_drift=$(variant up-old-drift)
insert_after "$up_recorded_drift/$k_int" 1 'drift'
run "$driver" prepare --overlay-dir "$ov" --lock "$lock_old" --work-dir "$scratch/work-drift" \
  --old-pristine-dir "$up_recorded_drift" --pristine-dir "$old" --target-tag "$tag_new"
[[ $rc == 4 ]] || fail "an overlay that does not match its own pin returned $rc, want 4"
pass 'prepare exits 4 when the recorded pre-images do not match the old release'


: >"$curl_log"
run env PATH="$stub_bin:$PATH" STUB_CURL_MODE=fail STUB_CURL_ARCHIVE="$archive_ok" STUB_CURL_LOG="$curl_log" \
  CE_OVERLAY_FETCH_RETRY_DELAY=0 "$driver" prepare --overlay-dir "$ov" --lock "$lock_old" --work-dir "$scratch/work-net"
[[ $rc == 2 ]] || fail "prepare with no upstream returned $rc, want 2: $err"
pass 'prepare exits 2 when upstream is unavailable'

: >"$curl_log"
run env PATH="$stub_bin:$PATH" STUB_CURL_MODE=serve STUB_CURL_ARCHIVE="$archive_ok" STUB_CURL_LOG="$curl_log" \
  "$driver" prepare --overlay-dir "$ov" --lock "$lock_old" --work-dir "$scratch/work-badtag" --target-tag v3.26.4
[[ $rc == 64 && ! -s $curl_log ]] || fail "a malformed target tag returned $rc or made a request"
lock_bad="$scratch/lock-bad-driver.json"
write_lock "$lock_bad" evil/compound-engineering-plugin "$tag_old"
run env PATH="$stub_bin:$PATH" STUB_CURL_MODE=serve STUB_CURL_ARCHIVE="$archive_ok" STUB_CURL_LOG="$curl_log" \
  "$driver" prepare --overlay-dir "$ov" --lock "$lock_bad" --work-dir "$scratch/work-badsource" --target-tag "$tag_new"
[[ $rc == 4 && ! -s $curl_log ]] || fail "a lock source outside the allowlist returned $rc or made a request"
pass 'driver refuses a malformed tag and a foreign lock source before any URL is built'

# --- driver: stamp -----------------------------------------------------------

ovs=$(fresh_overlay stamp-ok)
run "$driver" stamp --overlay-dir "$ovs" --lock "$lock_old" --pristine-dir "$old" --target-tag "$tag_new"
[[ $rc == 0 ]] || fail "stamp on unchanged pre-images returned $rc: $err"
[[ $(jq -r '.version' "$ovs/base.json") == "$tag_new" ]] || fail 'stamp did not move the tag'
[[ $(jq -S 'del(.version)' "$ov/base.json") == "$(jq -S 'del(.version)' "$ovs/base.json")" ]] || fail 'stamp changed more than the tag'
diff -r --exclude=base.json "$ov" "$ovs" >/dev/null || fail 'stamp changed a patch'
pass 'stamp changes only the tag'

for refusal in changed moded removed shipped; do
  ovs=$(fresh_overlay "stamp-$refusal")
  snap_first=$(snapshot "$ovs")
  case $refusal in
    changed) tree=$changed ;;
    moded) tree=$moded ;;
    removed) tree=$removed ;;
    shipped) tree=$shipped ;;
  esac
  run "$driver" stamp --overlay-dir "$ovs" --lock "$lock_old" --pristine-dir "$tree" --target-tag "$tag_new"
  [[ $rc == 1 ]] || fail "stamp with a $refusal pre-image returned $rc, want 1"
  [[ $(snapshot "$ovs") == "$snap_first" ]] || fail "stamp with a $refusal pre-image wrote to the overlay"
done
pass 'stamp refuses a changed, re-moded, removed, or shipped pre-image and writes nothing'

: >"$curl_log"
run env PATH="$stub_bin:$PATH" STUB_CURL_MODE=fail STUB_CURL_ARCHIVE="$archive_ok" STUB_CURL_LOG="$curl_log" \
  CE_OVERLAY_FETCH_RETRY_DELAY=0 "$driver" stamp --overlay-dir "$ovs" --lock "$lock_old" --target-tag "$tag_new"
[[ $rc == 2 ]] || fail "stamp with no upstream returned $rc, want 2"
pass 'stamp exits 2 when upstream is unavailable'

echo 'ce-overlay tooling: ok'
