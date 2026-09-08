#!/usr/bin/env bash
set -euo pipefail

# Drives .chezmoitemplates/orca-register.sh against a stubbed Orca CLI.
#
# WHY A STUB AND NOT THE REAL CLI. Registration talks to a running Orca runtime,
# which no CI runner has — the same reason .ci/test-garden-path-mirror-check.sh
# feeds its checker literals instead of a real garden. So the helper takes the
# CLI path from ORCA_REGISTER_CLI and reads already-parsed tree records on
# stdin; this test supplies both. Neither side needs what the other has.
#
# The stub records every invocation to $ORCA_STUB_LOG and answers from
# $ORCA_STUB_DIR/*.answer files, so each case below is one answer set plus one
# assertion on the log.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper="$repo_root/.chezmoitemplates/orca-register.sh"

fail() {
  printf 'test-orca-register: %s\n' "$*" >&2
  exit 1
}

pass() { printf '  ok  %s\n' "$*"; }

[ -f "$helper" ] || fail "helper not found at .chezmoitemplates/orca-register.sh"

grep -q '{{' "$helper" && fail 'helper contains a Go-template brace pair; includeTemplate renders it on the way in'

scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/orca-register.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

tab=$(printf '\t')
rec() { printf '%s%s%s%s%s%s%s\n' "$1" "$tab" "$2" "$tab" "$3" "$tab" "$4"; }

# One stub for every case. It answers `status --json` from status.answer, fails
# any subcommand named in fail_on, and otherwise exits 0 with the matching
# .answer file (empty when absent). `serve` marks itself started and flips the
# status answer to the file named by serve_becomes.
make_stub() {
  stub_dir="$scratch/stub.$1"
  mkdir -p "$stub_dir"
  cat >"$stub_dir/orca-ide" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ORCA_STUB_LOG"
sub="$1"; [ "$#" -gt 1 ] && sub="$1 $2"
case "$sub" in
  "status --json"|"status")
    if [ -f "$ORCA_STUB_DIR/serve.started" ] && [ -f "$ORCA_STUB_DIR/status.after-serve" ]; then
      cat "$ORCA_STUB_DIR/status.after-serve"
    else
      cat "$ORCA_STUB_DIR/status.answer"
    fi
    exit 0 ;;
  "serve"*)
    : >"$ORCA_STUB_DIR/serve.started"
    if [ -f "$ORCA_STUB_DIR/serve.fails" ]; then exit 1; fi
    # foreground-only, like the real CLI
    while [ ! -f "$ORCA_STUB_DIR/serve.stop" ]; do sleep 0.1; done
    exit 0 ;;
esac
for f in "$ORCA_STUB_DIR"/fail_on; do
  [ -f "$f" ] || continue
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    case "$*" in $pattern) printf 'stub: refusing %s\n' "$*" >&2; exit 7 ;; esac
  done <"$f"
done
# `project setups` answers the snapshot on its first call and the post-add list
# on every later call, so the helper's read-once-then-resolve shape is exercised.
if [ "$sub" = "project setups" ]; then
  if [ -f "$ORCA_STUB_DIR/setups.read" ] && [ -f "$ORCA_STUB_DIR/project_setups.after-add" ]; then
    cat "$ORCA_STUB_DIR/project_setups.after-add"
  else
    : >"$ORCA_STUB_DIR/setups.read"
    cat "$ORCA_STUB_DIR/project_setups.answer"
  fi
  exit 0
fi
answer="$ORCA_STUB_DIR/$(printf '%s' "$sub" | tr ' /' '__').answer"
[ -f "$answer" ] && cat "$answer"
exit 0
STUB
  chmod +x "$stub_dir/orca-ide"
  export ORCA_STUB_DIR="$stub_dir"
  export ORCA_STUB_LOG="$stub_dir/log"
  export ORCA_REGISTER_CLI="$stub_dir/orca-ide"
  : >"$ORCA_STUB_LOG"
  printf '{"appRunning":true,"runtimeState":"ready","runtimeReachable":true}\n' >"$stub_dir/status.answer"
  printf '{"ok":true,"result":{"setups":[]}}\n' >"$stub_dir/project_setups.answer"
  printf '{"ok":true,"result":{"repos":[]}}\n' >"$stub_dir/repo_list.answer"
  # The real `project setups --json` shape, taken from the live CLI: the entry
  # id is `id`, and `projectId` / `repoId` sit beside it with names ending in
  # the same three characters. A `setupId` key does not exist, and the
  # `<projectId>::<hostId>` selector the CLI's own help shows is rejected.
  cat >"$stub_dir/project_setups.after-add" <<EOF
{"ok":true,"result":{"setups":[
  {"id":"setup-a","projectId":"github:hyperlapse122/dotfiles","hostId":"local","repoId":"repo-a","path":"$scratch/src/github.com/hyperlapse122/dotfiles","setupState":"ready"},
  {"id":"setup-b","projectId":"jpi:products/365flow/pacs-scp","hostId":"local","repoId":"repo-b","path":"$scratch/src/git.jpi.app/products/365flow/pacs-scp","setupState":"ready"}
]}}
EOF
}

run_register() {
  set +e
  register_out=$(printf '%s' "$1" | ORCA_REGISTER_SERVE_TIMEOUT=2 bash -c '
    ORCA_REGISTER_SOURCED=1
    . "$1"
    orca_register_main
  ' _ "$helper" 2>&1)
  register_rc=$?
  set -e
}

logged() { grep -qF -- "$1" "$ORCA_STUB_LOG"; }

two_trees=$(
  rec dotfiles "$scratch/src/github.com/hyperlapse122/dotfiles" 'github.com/hyperlapse122/dotfiles' 'https://github.com/hyperlapse122/dotfiles.git'
  rec pacs-scp "$scratch/src/git.jpi.app/products/365flow/pacs-scp" 'git.jpi.app/products/365flow/pacs-scp' 'https://git.jpi.app/products/365flow/pacs-scp.git'
)

# --- reachable runtime: register, never invoke serve (AE3) --------------------

make_stub reachable
run_register "$two_trees"
[ "$register_rc" -eq 0 ] || fail "reachable run exited $register_rc: $register_out"
logged 'serve' && fail 'reachable run invoked serve'
logged 'repo add --path' || fail 'reachable run did not add a repo'
pass 'a reachable runtime is used as-is and serve is never invoked'

# --- display name and worktree base path reach setup-update (AE1) ------------

logged 'hyperlapse122 / dotfiles' || fail 'display name short form missing from setup-update'
logged '365flow / pacs-scp' || fail 'nested namespace short form missing from setup-update'
logged '--worktree-base-path' || fail 'worktree base path missing from setup-update'
logged '--setup setup-a' || fail 'setup-update did not use the setup entry id'
logged '--setup repo-a' && fail 'setup-update used the sibling repoId instead of the setup id'
logged '--setup github:hyperlapse122/dotfiles' && fail 'setup-update used the sibling projectId instead of the setup id'
pass 'setup-update carries the short display name, the worktree base path, and the setup entry id'

# --- the real `status --json` nested shape is recognised (AE3) ---------------
#
# The live CLI nests its answer as app.running / runtime.reachable and prints
# the flat appRunning / runtimeReachable only in its human-readable form. A
# probe that knows only the flat names reads every runtime as unreachable and
# starts serve underneath a running desktop app — observed for real before this
# case existed, so it is pinned with the verbatim live shape.

make_stub nested-status
cat >"$ORCA_STUB_DIR/status.answer" <<'EOF'
{
  "id": "local-status",
  "ok": true,
  "result": {
    "target": { "kind": "local" },
    "app": { "running": true, "pid": 11760, "desktopWindowStatus": "available" },
    "runtime": {
      "state": "ready",
      "reachable": true,
      "connectionState": "connected",
      "capabilities": ["runtime.status.compat.v1", "runtime.environments.v1"]
    }
  }
}
EOF
run_register "$two_trees"
[ "$register_rc" -eq 0 ] || fail "nested-status run exited $register_rc: $register_out"
logged 'serve' && fail 'nested-status run invoked serve under a running desktop app'
logged 'repo add --path' || fail 'nested-status run did not register'
pass 'the nested status --json shape is read as reachable and serve is never invoked'

# --- the nested shape with an unreachable runtime still refuses serve --------

make_stub nested-unreachable
cat >"$ORCA_STUB_DIR/status.answer" <<'EOF'
{"ok":true,"result":{"app":{"running":true},"runtime":{"state":"starting","reachable":false}}}
EOF
run_register "$two_trees"
[ "$register_rc" -ne 0 ] || fail 'nested app-running-but-unreachable run exited zero'
logged 'serve' && fail 'nested app-running-but-unreachable run invoked serve'
pass 'the nested shape with a running app and no runtime fails without serve'

# --- app running with an unreachable runtime: fail, never serve (AE3) --------

make_stub app-unreachable
printf '{"appRunning":true,"runtimeState":"starting","runtimeReachable":false}\n' >"$ORCA_STUB_DIR/status.answer"
run_register "$two_trees"
[ "$register_rc" -ne 0 ] || fail 'app-running-but-unreachable run exited zero'
logged 'serve' && fail 'app-running-but-unreachable run invoked serve'
case "$register_out" in *unreachable*) : ;; *) fail "error did not name the unreachable runtime: $register_out" ;; esac
pass 'a running app with an unreachable runtime fails without invoking serve'

# --- neither: start serve, register, stop only that PID (AE4) ----------------

make_stub headless
printf '{"appRunning":false,"runtimeState":"stopped","runtimeReachable":false}\n' >"$ORCA_STUB_DIR/status.answer"
printf '{"appRunning":false,"runtimeState":"ready","runtimeReachable":true}\n' >"$ORCA_STUB_DIR/status.after-serve"
printf '{"transports":[{"kind":"websocket","endpoint":"ws://127.0.0.1:6768"}]}\n' >"$ORCA_STUB_DIR/runtime.json"
ORCA_REGISTER_RUNTIME_FILE="$ORCA_STUB_DIR/runtime.json" run_register "$two_trees"
[ "$register_rc" -eq 0 ] || fail "headless run exited $register_rc: $register_out"
logged 'serve' || fail 'headless run did not invoke serve'
logged 'repo add --path' || fail 'headless run did not add a repo'
pass 'no reachable runtime starts serve, then registers'

# --- a self-started runtime that is not loopback-bound fails (AE11) ----------

make_stub non-loopback
printf '{"appRunning":false,"runtimeState":"stopped","runtimeReachable":false}\n' >"$ORCA_STUB_DIR/status.answer"
printf '{"appRunning":false,"runtimeState":"ready","runtimeReachable":true}\n' >"$ORCA_STUB_DIR/status.after-serve"
printf '{"transports":[{"kind":"websocket","endpoint":"ws://0.0.0.0:6768"}]}\n' >"$ORCA_STUB_DIR/runtime.json"
ORCA_REGISTER_RUNTIME_FILE="$ORCA_STUB_DIR/runtime.json" run_register "$two_trees"
[ "$register_rc" -ne 0 ] || fail 'non-loopback self-started runtime exited zero'
logged 'repo add --path' && fail 'non-loopback run registered a tree anyway'
case "$register_out" in *loopback*) : ;; *) fail "error did not name the loopback requirement: $register_out" ;; esac
pass 'a self-started runtime that is not loopback-bound fails before registering'

# --- serve that never becomes reachable fails at the bounded timeout ---------

make_stub serve-never-ready
printf '{"appRunning":false,"runtimeState":"stopped","runtimeReachable":false}\n' >"$ORCA_STUB_DIR/status.answer"
run_register "$two_trees"
[ "$register_rc" -ne 0 ] || fail 'never-reachable serve exited zero'
case "$register_out" in *timeout*|*timed\ out*) : ;; *) fail "error did not name the timeout: $register_out" ;; esac
pass 'a serve that never becomes reachable fails at the bounded timeout'

# --- an existing local setup is left untouched (AE2) -------------------------

make_stub existing-setup
cat >"$ORCA_STUB_DIR/project_setups.answer" <<EOF
{"ok":true,"result":{"setups":[
  {"id":"setup-a","projectId":"github:hyperlapse122/dotfiles","hostId":"local","repoId":"repo-a","path":"$scratch/src/github.com/hyperlapse122/dotfiles","worktreeBasePath":"$HOME/.local/share/worktrees"}
]}}
EOF
run_register "$two_trees"
[ "$register_rc" -eq 0 ] || fail "existing-setup run exited $register_rc: $register_out"
logged "repo add --path $scratch/src/github.com/hyperlapse122/dotfiles" && fail 'an already-registered tree was re-added'
logged "repo add --path $scratch/src/git.jpi.app/products/365flow/pacs-scp" || fail 'the unregistered tree was skipped'
pass 'a tree with a local setup is left untouched while the other is registered'

# --- a repo present without a setup is completed, not skipped ----------------

make_stub repo-without-setup
cat >"$ORCA_STUB_DIR/repo_list.answer" <<EOF
{"ok":true,"result":{"repos":[
  {"id":"repo-a","path":"$scratch/src/github.com/hyperlapse122/dotfiles"}
]}}
EOF
run_register "$two_trees"
[ "$register_rc" -eq 0 ] || fail "repo-without-setup run exited $register_rc: $register_out"
logged 'setup-update' || fail 'a repo present without a local setup was skipped instead of completed'
pass 'a repo present without a local setup is completed rather than skipped'

# --- a failing repo add aborts and names the tree and the operation (AE5) ----

make_stub add-fails
printf 'repo add*\n' >"$ORCA_STUB_DIR/fail_on"
run_register "$two_trees"
[ "$register_rc" -ne 0 ] || fail 'failing repo add exited zero'
case "$register_out" in *dotfiles*) : ;; *) fail "error did not name the tree: $register_out" ;; esac
case "$register_out" in *"repo add"*) : ;; *) fail "error did not name the operation: $register_out" ;; esac
pass 'a failing repo add aborts the run naming the tree and the operation'

# --- no executable CLI on either path fails naming both ----------------------

make_stub no-cli
unset ORCA_REGISTER_CLI
ORCA_REGISTER_HOME_CLI="$scratch/absent/orca-ide" ORCA_REGISTER_RPM_CLI="$scratch/absent/opt-orca-ide" run_register "$two_trees"
[ "$register_rc" -ne 0 ] || fail 'missing CLI exited zero'
case "$register_out" in *absent/orca-ide*) : ;; *) fail "error did not name the home CLI path: $register_out" ;; esac
case "$register_out" in *absent/opt-orca-ide*) : ;; *) fail "error did not name the RPM CLI path: $register_out" ;; esac
pass 'neither CLI path executable fails naming both paths'

# --- the RPM path is used when the home symlink is absent --------------------

make_stub rpm-fallback
unset ORCA_REGISTER_CLI
ORCA_REGISTER_HOME_CLI="$scratch/absent/orca-ide" ORCA_REGISTER_RPM_CLI="$ORCA_STUB_DIR/orca-ide" run_register "$two_trees"
[ "$register_rc" -eq 0 ] || fail "rpm-fallback run exited $register_rc: $register_out"
logged 'repo add --path' || fail 'rpm fallback did not register'
pass 'the RPM-installed CLI is used when the home symlink is absent'

# --- an empty record set does nothing at all ---------------------------------

make_stub empty
run_register ''
[ "$register_rc" -eq 0 ] || fail "empty run exited $register_rc: $register_out"
[ ! -s "$ORCA_STUB_LOG" ] || fail "empty run invoked the CLI: $(cat "$ORCA_STUB_LOG")"
pass 'an empty record set exits zero and invokes no CLI command'

printf 'test-orca-register: all checks passed\n'
