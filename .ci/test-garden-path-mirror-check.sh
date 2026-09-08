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

printf 'test-garden-path-mirror-check: all cases passed\n'
