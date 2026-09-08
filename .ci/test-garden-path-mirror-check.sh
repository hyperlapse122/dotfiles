#!/usr/bin/env bash
set -euo pipefail

# Drives .chezmoitemplates/garden-path-mirror-check.sh through its accept and
# reject paths.
#
# WHY THE CHECKER TAKES A STREAM. The ~/src layout rule is enforced at
# `chezmoi apply`, not here, because the garden registry is GPG-encrypted and no
# runner holds the key — `.ci/test-ci-wiring.sh` already records that no runner
# provisions garden either. So the checker parses no YAML and calls no external
# tool: it reads `name<TAB>declared-path<TAB>url` records on stdin. The apply
# gate builds that stream from `garden ls`; this test builds it from literals.
# Neither side needs what the other has.
#
# The reject cases map onto the ways a declaration can drift from its remote:
# a segment dropped, a group renamed, a path escaping the registry root, and a
# record that carries no remote at all.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
checker="$repo_root/.chezmoitemplates/garden-path-mirror-check.sh"

fail() {
  printf 'test-garden-path-mirror-check: %s\n' "$*" >&2
  exit 1
}

pass() { printf '  ok  %s\n' "$*"; }

[ -f "$checker" ] || fail "checker not found at .chezmoitemplates/garden-path-mirror-check.sh"

# Source the helper so the record producer can be driven directly. The guard
# stops the sourced copy from consuming stdin on its own.
GARDEN_PATH_MIRROR_SOURCED=1
# shellcheck source=.chezmoitemplates/garden-path-mirror-check.sh
. "$checker"

# Run the checker over a stream, capturing status and output together.
run_checker() {
  set +e
  checker_out=$(printf '%s\n' "$1" | sh "$checker" 2>&1)
  checker_rc=$?
  set -e
}

tab=$(printf '\t')
rec() { printf '%s%s%s%s%s\n' "$1" "$tab" "$2" "$tab" "$3"; }

# --- accept: every declaration already mirrors its remote ---------------------

conforming=$(
  rec dotfiles 'github.com/hyperlapse122/dotfiles' 'https://github.com/hyperlapse122/dotfiles.git'
  rec pacs-scp 'git.jpi.app/products/365flow/pacs-scp' 'https://git.jpi.app/products/365flow/pacs-scp.git'
  rec signet 'git.jpi.app/products/signet' 'https://git.jpi.app/products/signet.git'
)
run_checker "$conforming"
[ "$checker_rc" -eq 0 ] || fail "conforming stream exited $checker_rc: $checker_out"
[ -z "$checker_out" ] || fail "conforming stream printed output: $checker_out"
pass 'a conforming stream exits zero and prints nothing'

# --- reject: an umbrella segment dropped from the declared path ---------------

run_checker "$(rec pacs-scp 'git.jpi.app/365flow/pacs-scp' 'https://git.jpi.app/products/365flow/pacs-scp.git')"
[ "$checker_rc" -ne 0 ] || fail 'a dropped umbrella segment was accepted'
case "$checker_out" in
  *pacs-scp*) ;;
  *) fail "rejection did not name the tree: $checker_out" ;;
esac
case "$checker_out" in
  *'git.jpi.app/365flow/pacs-scp'*) ;;
  *) fail "rejection did not name the declared path: $checker_out" ;;
esac
case "$checker_out" in
  *'git.jpi.app/products/365flow/pacs-scp'*) ;;
  *) fail "rejection did not name the derived path: $checker_out" ;;
esac
pass 'a dropped umbrella segment is rejected, naming tree and both paths'

# --- the .git suffix is not part of the namespace ----------------------------

run_checker "$(rec works 'git.jpi.app/hyperlapse/works' 'https://git.jpi.app/hyperlapse/works')"
[ "$checker_rc" -eq 0 ] || fail "a url without .git was rejected: $checker_out"
pass 'a url with and without the .git suffix derive the same path'

# --- ssh remotes in the scp-like form ----------------------------------------

run_checker "$(rec fleet 'git.jpi.app/infra/fleet' 'git@git.jpi.app:infra/fleet.git')"
[ "$checker_rc" -eq 0 ] || fail "an ssh remote was rejected: $checker_out"
pass 'an ssh git@host:namespace/project.git remote derives host/namespace/project'

# --- userinfo and port are not path segments ---------------------------------

run_checker "$(rec fleet 'git.jpi.app/infra/fleet' 'https://deploy@git.jpi.app:8443/infra/fleet.git')"
[ "$checker_rc" -eq 0 ] || fail "userinfo/port were treated as path: $checker_out"
pass 'userinfo and a port suffix derive the same path as the bare host'

# --- reverse direction: the mapping is reversible (R3) ------------------------

for url in \
  'https://github.com/hyperlapse122/dotfiles.git' \
  'https://git.jpi.app/products/365flow/pacs-scp.git' \
  'git@git.jpi.app:infra/fleet.git' \
  'https://deploy@git.jpi.app:8443/infra/fleet.git'; do
  derived=$(printf 'x%sPLACEHOLDER%s%s\n' "$tab" "$tab" "$url" | sh "$checker" --print 2>&1) ||
    fail "--print failed for $url"
  host=${derived%%/*}
  namespace=${derived#*/}
  # Recombining the derived path with the remote's own scheme reproduces the url.
  case "$url" in
    *://*)
      scheme=${url%%://*}
      rebuilt="$scheme://$host/$namespace.git"
      expected=$(printf '%s' "$url" | sed -e 's|://[^@/]*@|://|' -e 's|\(://[^/]*\):[0-9]*/|\1/|')
      case "$expected" in *.git) ;; *) expected="$expected.git" ;; esac
      ;;
    *)
      rebuilt="git@$host:$namespace.git"
      expected=$url
      ;;
  esac
  [ "$rebuilt" = "$expected" ] ||
    fail "derived path did not reconstruct the url: $rebuilt != $expected"
done
pass 'a derived path recombined with its scheme reconstructs the url'

# --- reject: a declared path outside the registry root ------------------------

run_checker "$(rec fleet '/home/h82/src/git.jpi.app/infra/fleet' 'https://git.jpi.app/infra/fleet.git')"
[ "$checker_rc" -ne 0 ] || fail 'an absolute declared path was accepted'
pass 'a declared path outside the registry root is a deviation'

# --- reject: a record with no remote ------------------------------------------

run_checker "$(rec orphan 'git.jpi.app/infra/orphan' '')"
[ "$checker_rc" -ne 0 ] || fail 'a record with no url was accepted'
case "$checker_out" in
  *orphan*) ;;
  *) fail "malformed record did not name the tree: $checker_out" ;;
esac
pass 'a record with an empty url is reported as malformed'

# --- every deviation is reported, not just the first --------------------------

two_bad=$(
  rec pacs-scp 'git.jpi.app/365flow/pacs-scp' 'https://git.jpi.app/products/365flow/pacs-scp.git'
  rec examvue-apps 'git.jpi.app/examvue-duo/examvue-apps' 'https://git.jpi.app/products/examvue-duo/examvue-apps.git'
)
run_checker "$two_bad"
[ "$checker_rc" -ne 0 ] || fail 'two deviations were accepted'
case "$checker_out" in
  *pacs-scp*examvue-apps* | *examvue-apps*pacs-scp*) ;;
  *) fail "only one of two deviations was reported: $checker_out" ;;
esac
pass 'every deviation in a stream is reported'

# --- case is part of the namespace -------------------------------------------

run_checker "$(rec ExamVueDuo_AI 'git.jpi.app/products/examvue-duo/examvueduo_ai' 'https://git.jpi.app/products/examvue-duo/ExamVueDuo_AI.git')"
[ "$checker_rc" -ne 0 ] || fail 'a case-folded path was accepted'
pass 'a path differing only in segment case is a deviation'

# --- reject: a url no path can be derived from ---------------------------------

for bad_url in 'https://onlyhost' 'git@onlyhost' 'https://git.jpi.app/'; do
  run_checker "$(rec bad 'git.jpi.app/x' "$bad_url")"
  [ "$checker_rc" -ne 0 ] || fail "underivable url was accepted: $bad_url"
  case "$checker_out" in
    *'no path can be derived from'*) ;;
    *) fail "underivable url gave the wrong message for $bad_url: $checker_out" ;;
  esac
done
pass 'a url with no derivable namespace is rejected'

# --- a trailing slash does not defeat the .git strip ---------------------------

run_checker "$(rec fleet 'git.jpi.app/infra/fleet' 'https://git.jpi.app/infra/fleet.git/')"
[ "$checker_rc" -eq 0 ] || fail "a trailing slash left .git in the path: $checker_out"
pass 'a url with a trailing slash after .git derives the same path'

# --- the record producer: garden ls text in, records out -----------------------
#
# This half of the gate has no other coverage: CI provisions no `garden`, but
# the producer is a pure text transform, so recorded output exercises it fully.

ls_fixture=$(cat <<'LS'
# grown [main] /home/u/src/example.com/ns/grown
remotes:
  origin: https://example.com/ns/grown.git

#- ungrown /home/u/src/example.com/ns/ungrown
remotes:
  origin: https://example.com/ns/ungrown.git

#- no-remote /home/u/src/totally/wrong/place
LS
)

records=$(printf '%s\n' "$ls_fixture" | garden_path_mirror_records '/home/u/src')

[ "$(printf '%s\n' "$records" | grep -c .)" -eq 3 ] ||
  fail "producer emitted $(printf '%s\n' "$records" | grep -c .) records, expected 3: $records"
pass 'every tree header produces exactly one record'

case "$records" in
  *"grown${tab}/home/u/src/example.com/ns/grown${tab}example.com/ns/grown${tab}https://example.com/ns/grown.git"*) ;;
  *) fail "grown tree record is wrong: $records" ;;
esac
case "$records" in
  *"ungrown${tab}/home/u/src/example.com/ns/ungrown${tab}example.com/ns/ungrown${tab}https://example.com/ns/ungrown.git"*) ;;
  *) fail "ungrown tree record is wrong: $records" ;;
esac
pass 'grown and ungrown headers both pair with their origin line'

# The regression this pins: a tree with no origin line must still emit a record
# with an empty url, so it reaches the malformed-record path instead of
# vanishing from both apply-time gates.
case "$records" in
  *"no-remote${tab}/home/u/src/totally/wrong/place${tab}totally/wrong/place${tab}"*) ;;
  *) fail "a tree with no origin line was dropped: $records" ;;
esac
pass 'a tree with no origin line still produces a record'

# The reconcile drops the absolute-path column before calling the check, so the
# fixture does the same; otherwise every record would fail as "outside the root".
check_out=$(printf '%s\n' "$records" | cut -f1,3,4 | garden_path_mirror_check 2>&1) &&
  fail 'the no-remote tree passed the check'
case "$check_out" in
  *'no-remote'*'declares no remote url'*) ;;
  *) fail "the no-remote tree was not reported as malformed: $check_out" ;;
esac
case "$check_out" in
  *grown*) fail "a conforming tree was wrongly reported: $check_out" ;;
  *) ;;
esac
pass 'the no-remote tree is reported as malformed, and the others pass'

# --- the header count matches the record count ---------------------------------

[ "$(printf '%s\n' "$ls_fixture" | garden_path_mirror_header_count)" -eq 3 ] ||
  fail 'header count did not match the three declared trees'
pass 'the header count matches the number of declared trees'

# --- a garden root containing regex metacharacters -----------------------------

meta_records=$(printf '%s\n' '#- t /home/u/s+rc/example.com/ns/t
remotes:
  origin: https://example.com/ns/t.git' | garden_path_mirror_records '/home/u/s+rc')
case "$meta_records" in
  *"${tab}example.com/ns/t${tab}"*) ;;
  *) fail "a root with regex metacharacters mis-stripped: $meta_records" ;;
esac
pass 'the root prefix is stripped literally, not as a regex'

printf 'test-garden-path-mirror-check: all cases passed\n'
