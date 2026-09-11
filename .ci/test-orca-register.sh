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
    printf '%s\n' "$$" >"$ORCA_STUB_DIR/serve.pid"
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
  # The group step is opt-in per case: with no records the helper returns before
  # it looks for a runtime client at all.
  unset ORCA_REGISTER_GROUP_RECORDS
  : >"$ORCA_STUB_LOG"
  printf '{"appRunning":true,"runtimeState":"ready","runtimeReachable":true}\n' >"$stub_dir/status.answer"
  printf '{"id":"rpc-envelope-id","ok":true,"result":{"setups":[]}}\n' >"$stub_dir/project_setups.answer"
  printf '{"id":"rpc-envelope-id","ok":true,"result":{"repos":[]}}\n' >"$stub_dir/repo_list.answer"
  # The real `project setups --json` shape, taken from the live CLI: the entry
  # id is `id`, and `projectId` / `repoId` sit beside it with names ending in
  # the same three characters. A `setupId` key does not exist, and the
  # `<projectId>::<hostId>` selector the CLI's own help shows is rejected.
  #
  # The envelope's OWN `id` (the request id) leads every response and the
  # `_meta` block trails it. Both are here because the id lookup has to reach
  # past them: matching the first `"id"` on the line resolved the request id
  # for whichever tree came first in the list.
  cat >"$stub_dir/project_setups.after-add" <<EOF
{"id":"rpc-envelope-id","ok":true,"result":{"setups":[
  {"id":"setup-a","projectId":"github:hyperlapse122/dotfiles","hostId":"local","repoId":"repo-a","path":"$scratch/src/github.com/hyperlapse122/dotfiles","setupState":"ready"},
  {"id":"setup-b","projectId":"git:git.example.org/tenants/blue-team/widget-service","hostId":"local","repoId":"repo-b","path":"$scratch/src/git.example.org/tenants/blue-team/widget-service","setupState":"ready"}
]},"_meta":{"runtimeId":"rpc-runtime-id"}}
EOF
}

run_register() {
  set +e
  # `set -euo pipefail` mirrors the apply script exactly. Without it this
  # harness ran the helper under looser shell options than production, and an
  # errexit abort inside a helper pipeline passed here while killing a real
  # apply before its own diagnostic could print.
  register_out=$(printf '%s' "$1" | ORCA_REGISTER_SERVE_TIMEOUT=2 bash -c '
    set -euo pipefail
    ORCA_REGISTER_SOURCED=1
    . "$1"
    orca_register_main
  ' _ "$helper" 2>&1)
  register_rc=$?
  set -e
}

logged() { grep -qF -- "$1" "$ORCA_STUB_LOG"; }

# The second tree carries a namespace deeper than one segment, which is what
# the display-name and identity cases below actually exercise. Its host and path
# are invented: this file is public, and the real registry that supplies them at
# apply time is GPG-encrypted for that reason.
two_trees=$(
  rec dotfiles "$scratch/src/github.com/hyperlapse122/dotfiles" 'github.com/hyperlapse122/dotfiles' 'https://github.com/hyperlapse122/dotfiles.git'
  rec widget-service "$scratch/src/git.example.org/tenants/blue-team/widget-service" 'git.example.org/tenants/blue-team/widget-service' 'https://git.example.org/tenants/blue-team/widget-service.git'
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
logged 'blue-team / widget-service' || fail 'nested namespace short form missing from setup-update'
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
serve_pid=$(cat "$ORCA_STUB_DIR/serve.pid" 2>/dev/null || true)
[ -n "$serve_pid" ] || fail 'headless run recorded no serve pid'
kill -0 "$serve_pid" 2>/dev/null && fail "the self-started serve ($serve_pid) is still running after a successful run"
pass 'no reachable runtime starts serve, registers, and stops the runtime it started'

# --- a self-started runtime with NO local transport fails (AE11) -------------

make_stub non-loopback
printf '{"appRunning":false,"runtimeState":"stopped","runtimeReachable":false}\n' >"$ORCA_STUB_DIR/status.answer"
printf '{"appRunning":false,"runtimeState":"ready","runtimeReachable":true}\n' >"$ORCA_STUB_DIR/status.after-serve"
printf '{"transports":[{"kind":"websocket","endpoint":"ws://0.0.0.0:6768"}]}\n' >"$ORCA_STUB_DIR/runtime.json"
ORCA_REGISTER_RUNTIME_FILE="$ORCA_STUB_DIR/runtime.json" run_register "$two_trees"
[ "$register_rc" -ne 0 ] || fail 'non-loopback self-started runtime exited zero'
logged 'repo add --path' && fail 'non-loopback run registered a tree anyway'
case "$register_out" in *loopback*) : ;; *) fail "error did not name the loopback requirement: $register_out" ;; esac
serve_pid=$(cat "$ORCA_STUB_DIR/serve.pid" 2>/dev/null || true)
[ -n "$serve_pid" ] || fail 'loopback-refusal run recorded no serve pid'
kill -0 "$serve_pid" 2>/dev/null && fail "the refused runtime ($serve_pid) is still listening after the apply failed"
pass 'a self-started runtime with no local transport fails before registering AND is stopped'

# --- the real `orca serve` shape: unix socket + 0.0.0.0 websocket ------------
# Orca binds its websocket to 0.0.0.0 and offers no bind-address option, so the
# runtime always advertises one exposed endpoint beside its unix socket. The
# local transport is what registration travels over, so the run proceeds and
# only warns about the exposed listener.

make_stub mixed-transports
printf '{"appRunning":false,"runtimeState":"stopped","runtimeReachable":false}\n' >"$ORCA_STUB_DIR/status.answer"
printf '{"appRunning":false,"runtimeState":"ready","runtimeReachable":true}\n' >"$ORCA_STUB_DIR/status.after-serve"
printf '{"transports":[{"kind":"unix","endpoint":"/tmp/orca-test.sock"},{"kind":"websocket","endpoint":"ws://0.0.0.0:6768"}]}\n' >"$ORCA_STUB_DIR/runtime.json"
ORCA_REGISTER_RUNTIME_FILE="$ORCA_STUB_DIR/runtime.json" run_register "$two_trees"
[ "$register_rc" -eq 0 ] || fail "mixed-transport run exited $register_rc: $register_out"
logged 'repo add --path' || fail 'mixed-transport run did not register'
case "$register_out" in *'beyond loopback'*) : ;; *) fail "the exposed listener was not warned about: $register_out" ;; esac
pass 'a unix socket beside a 0.0.0.0 websocket registers and warns'

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
{"id":"rpc-envelope-id","ok":true,"result":{"setups":[
  {"id":"setup-a","projectId":"github:hyperlapse122/dotfiles","hostId":"local","repoId":"repo-a","path":"$scratch/src/github.com/hyperlapse122/dotfiles","worktreeBasePath":"$HOME/.local/share/worktrees"}
]},"_meta":{"runtimeId":"rpc-runtime-id"}}
EOF
run_register "$two_trees"
[ "$register_rc" -eq 0 ] || fail "existing-setup run exited $register_rc: $register_out"
logged "repo add --path $scratch/src/github.com/hyperlapse122/dotfiles" && fail 'an already-registered tree was re-added'
logged "repo add --path $scratch/src/git.example.org/tenants/blue-team/widget-service" || fail 'the unregistered tree was skipped'
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

# --- no executable CLI on either path SKIPS, naming both ---------------------
#
# This script runs on every managed host and the Orca desktop package is
# Fedora-only, so "Orca is not installed here" must not fail the apply.

make_stub no-cli
unset ORCA_REGISTER_CLI
ORCA_REGISTER_HOME_CLI="$scratch/absent/orca-ide" ORCA_REGISTER_RPM_CLI="$scratch/absent/opt-orca-ide" run_register "$two_trees"
[ "$register_rc" -eq 0 ] || fail "missing CLI exited $register_rc instead of skipping: $register_out"
case "$register_out" in *absent/orca-ide*) : ;; *) fail "skip notice did not name the home CLI path: $register_out" ;; esac
case "$register_out" in *absent/opt-orca-ide*) : ;; *) fail "skip notice did not name the RPM CLI path: $register_out" ;; esac
case "$register_out" in *skipping*) : ;; *) fail "skip notice did not say it was skipping: $register_out" ;; esac
pass 'a host with no Orca CLI skips registration instead of failing the apply'

# --- a failed snapshot read aborts instead of re-adding everything -----------
#
# An empty snapshot reads as "Orca knows nothing", which would invert the
# additive-only contract and re-add every declared tree.

make_stub setups-read-fails
printf 'project setups*\n' >"$ORCA_STUB_DIR/fail_on"
run_register "$two_trees"
[ "$register_rc" -ne 0 ] || fail 'a failing project-setups snapshot read exited zero'
logged 'repo add --path' && fail 'a failing snapshot read still re-added trees'
case "$register_out" in *"project setups"*) : ;; *) fail "error did not name the failing read: $register_out" ;; esac
pass 'a failing setups snapshot aborts rather than re-adding every tree'

make_stub repos-read-fails
printf 'repo list*\n' >"$ORCA_STUB_DIR/fail_on"
run_register "$two_trees"
[ "$register_rc" -ne 0 ] || fail 'a failing repo-list snapshot read exited zero'
logged 'repo add --path' && fail 'a failing repo-list read still re-added trees'
pass 'a failing repo-list snapshot aborts rather than re-adding every tree'

# --- no matching setup after a successful add names the tree (not errexit) ---
#
# The lookup is a pipeline; under the apply script's set -euo pipefail an
# unguarded substitution aborted here before this diagnostic could print.

make_stub setup-missing-after-add
printf '{"id":"rpc-envelope-id","ok":true,"result":{"setups":[]}}\n' >"$ORCA_STUB_DIR/project_setups.after-add"
run_register "$two_trees"
[ "$register_rc" -ne 0 ] || fail 'missing setup after add exited zero'
case "$register_out" in *dotfiles*) : ;; *) fail "error did not name the tree: $register_out" ;; esac
case "$register_out" in *"project setups"*) : ;; *) fail "error did not name the operation: $register_out" ;; esac
pass 'a repo added with no resulting setup names the tree and the operation'

# --- a nested member inside a setup entry does not break the id lookup -------
#
# The same flat-vs-nested assumption that already broke the status probe.

make_stub nested-setup-entry
cat >"$ORCA_STUB_DIR/project_setups.after-add" <<EOF
{"id":"rpc-envelope-id","ok":true,"result":{"setups":[
  {"id":"setup-a","projectId":"github:hyperlapse122/dotfiles","hostId":"local","repoId":"repo-a","hooks":{"mode":"auto","scripts":{"setup":""}},"path":"$scratch/src/github.com/hyperlapse122/dotfiles"},
  {"id":"setup-b","projectId":"git:git.example.org/tenants/blue-team/widget-service","hostId":"local","repoId":"repo-b","hooks":{"mode":"auto","scripts":{"setup":""}},"path":"$scratch/src/git.example.org/tenants/blue-team/widget-service"}
]},"_meta":{"runtimeId":"rpc-runtime-id"}}
EOF
run_register "$two_trees"
[ "$register_rc" -eq 0 ] || fail "nested setup entry exited $register_rc: $register_out"
logged '--setup rpc-envelope-id' && fail 'the id lookup resolved the response envelope id'
logged '--setup setup-a' || fail 'nested setup entry broke the id lookup'
pass 'a setup entry carrying a nested member still resolves its own id'

# --- an unreadable status refuses rather than starting a runtime blind -------

make_stub empty-status
: >"$ORCA_STUB_DIR/status.answer"
run_register "$two_trees"
[ "$register_rc" -ne 0 ] || fail 'an empty status probe exited zero'
logged 'serve' && fail 'an empty status probe started a runtime blind'
pass 'an unreadable status refuses instead of starting a runtime blind'

# --- a runtime file that has not appeared yet keeps polling ------------------

make_stub runtime-file-late
printf '{"appRunning":false,"runtimeState":"stopped","runtimeReachable":false}\n' >"$ORCA_STUB_DIR/status.answer"
printf '{"appRunning":false,"runtimeState":"ready","runtimeReachable":true}\n' >"$ORCA_STUB_DIR/status.after-serve"
ORCA_REGISTER_RUNTIME_FILE="$ORCA_STUB_DIR/absent-runtime.json" run_register "$two_trees"
[ "$register_rc" -ne 0 ] || fail 'an absent runtime file exited zero'
case "$register_out" in *loopback*) fail "an absent runtime file was reported as a loopback refusal: $register_out" ;; esac
case "$register_out" in *timeout*|*timed\ out*) : ;; *) fail "an absent runtime file did not time out: $register_out" ;; esac
pass 'a runtime file that never appears times out rather than reading as non-loopback'

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

# --- project groups ----------------------------------------------------------
#
# Grouping does not go through the CLI: Orca exposes `projectGroup.list`,
# `projectGroup.create` and `projectGroup.moveProject` only as runtime RPC
# methods, which the helper reaches through the CLI's own client module in
# ELECTRON_RUN_AS_NODE mode. So these cases stub the MODULE, not the CLI: a fake
# RuntimeClient that logs every call and answers from files. That keeps the real
# reconciler — the JavaScript the helper emits — under test, which is where the
# group-name and ordering decisions actually live.

group_module="$scratch/fake-runtime-client.js"
cat >"$group_module" <<'FAKE'
const fs = require('node:fs');

let created = 0;

function answer(name, fallback) {
  const path = process.env.ORCA_RPC_DIR + '/' + name;
  if (!fs.existsSync(path)) return fallback;
  return JSON.parse(fs.readFileSync(path, 'utf8'));
}

class RuntimeClient {
  async call(method, params) {
    fs.appendFileSync(process.env.ORCA_RPC_LOG, method + ' ' + JSON.stringify(params) + '\n');
    if (fs.existsSync(process.env.ORCA_RPC_DIR + '/fail.' + method)) {
      return { ok: false, error: { code: 'stub', message: 'refusing ' + method } };
    }
    if (method === 'projectGroup.list') return { ok: true, result: answer('groups.json', { groups: [] }) };
    if (method === 'repo.list') return { ok: true, result: answer('repos.json', { repos: [] }) };
    if (method === 'projectGroup.create') {
      created += 1;
      return { ok: true, result: { group: { id: 'group-' + created, name: params.name } } };
    }
    return { ok: true, result: {} };
  }
}

module.exports = { RuntimeClient };
FAKE

make_group_stub() {
  make_stub "$1"
  rpc_dir="$scratch/rpc.$1"
  mkdir -p "$rpc_dir"
  export ORCA_RPC_DIR="$rpc_dir"
  export ORCA_RPC_LOG="$rpc_dir/log"
  : >"$ORCA_RPC_LOG"
  export ORCA_REGISTER_NODE="$node_bin"
  export ORCA_REGISTER_RPC_MODULE="$group_module"
  cat >"$rpc_dir/repos.json" <<EOF
{"repos":[
  {"id":"repo-a","path":"$scratch/src/github.com/hyperlapse122/dotfiles","displayName":"hyperlapse122 / dotfiles"},
  {"id":"repo-b","path":"$scratch/src/git.example.org/tenants/blue-team/widget-service","displayName":"blue-team / widget-service"}
]}
EOF
  # A group name with spaces on purpose: it is what the group name may hold and
  # what the shell helpers beside this step cannot carry, which is why the
  # reconciler parses JSON instead of matching stripped blobs.
  export ORCA_REGISTER_GROUP_RECORDS="Blue Team Suite${tab}$scratch/src/git.example.org/tenants/blue-team/widget-service
"
}

rpc_logged() { grep -qF -- "$1" "$ORCA_RPC_LOG"; }

node_bin=$(command -v node || true)
if [ -z "$node_bin" ]; then
  printf '  --  skipping the project-group cases: no node on PATH\n'
else
  # --- a declared group is created and the project filed under it ------------

  make_group_stub groups-create
  run_register "$two_trees"
  [ "$register_rc" -eq 0 ] || fail "groups-create run exited $register_rc: $register_out"
  rpc_logged '"name":"Blue Team Suite"' || fail 'the declared group name never reached projectGroup.create'
  rpc_logged '"repo":"repo-b"' || fail 'the declared member was not moved into the group'
  rpc_logged '"groupId":"group-1"' || fail 'moveProject did not use the id of the group it just created'
  grep -qF '"repo":"repo-a"' "$ORCA_RPC_LOG" && fail 'an undeclared project was moved into the group'
  pass 'a declared group is created once and its declared members are filed under it'

  # --- an existing group of the same name is reused, never recreated ---------

  make_group_stub groups-reuse
  printf '{"groups":[{"id":"group-existing","name":"Blue Team Suite"}]}\n' >"$ORCA_RPC_DIR/groups.json"
  run_register "$two_trees"
  [ "$register_rc" -eq 0 ] || fail "groups-reuse run exited $register_rc: $register_out"
  rpc_logged 'projectGroup.create' && fail 'an existing group with the declared name was recreated'
  rpc_logged '"groupId":"group-existing"' || fail 'the existing group id was not used'
  pass 'a group that already carries the declared name is reused'

  # --- a project the operator already filed somewhere is left alone ----------

  make_group_stub groups-additive
  cat >"$ORCA_RPC_DIR/repos.json" <<EOF
{"repos":[
  {"id":"repo-b","path":"$scratch/src/git.example.org/tenants/blue-team/widget-service","displayName":"blue-team / widget-service","projectGroupId":"group-operator"}
]}
EOF
  run_register "$two_trees"
  [ "$register_rc" -eq 0 ] || fail "groups-additive run exited $register_rc: $register_out"
  rpc_logged 'projectGroup.moveProject' && fail "a project the operator had already grouped was moved"
  pass 'a project that already belongs to a group is never re-filed'

  # --- a new member lands past the last position, not at the member count ----

  make_group_stub groups-order
  printf '{"groups":[{"id":"group-existing","name":"Blue Team Suite"}]}\n' >"$ORCA_RPC_DIR/groups.json"
  cat >"$ORCA_RPC_DIR/repos.json" <<EOF
{"repos":[
  {"id":"repo-a","path":"$scratch/src/github.com/hyperlapse122/dotfiles","displayName":"hyperlapse122 / dotfiles","projectGroupId":"group-existing","projectGroupOrder":5},
  {"id":"repo-b","path":"$scratch/src/git.example.org/tenants/blue-team/widget-service","displayName":"blue-team / widget-service"}
]}
EOF
  run_register "$two_trees"
  [ "$register_rc" -eq 0 ] || fail "groups-order run exited $register_rc: $register_out"
  rpc_logged '"order":6' || fail "a new member did not land past the last taken position: $(cat "$ORCA_RPC_LOG")"
  pass 'a new group member lands past the last position already taken'

  # --- grouping is best effort: a failing RPC does not fail the apply --------

  make_group_stub groups-soft-fail
  : >"$ORCA_RPC_DIR/fail.projectGroup.list"
  run_register "$two_trees"
  [ "$register_rc" -eq 0 ] || fail "a failing group RPC failed the apply (rc $register_rc): $register_out"
  logged 'repo add --path' || fail 'the soft-fail run skipped registration'
  case "$register_out" in
    *"not grouped"*) ;;
    *) fail "a failing group RPC produced no warning: $register_out" ;;
  esac
  pass 'a failing group RPC warns and leaves the registration green'

  # --- an install with no runtime client module warns and continues ----------

  make_group_stub groups-no-module
  ORCA_REGISTER_RPC_MODULE="$scratch/absent/runtime-client.js" run_register "$two_trees"
  [ "$register_rc" -eq 0 ] || fail "a missing runtime client module failed the apply: $register_out"
  case "$register_out" in
    *"not grouped"*) ;;
    *) fail "a missing runtime client module produced no warning: $register_out" ;;
  esac
  pass 'an install with no runtime client module warns and registers anyway'

  unset ORCA_REGISTER_GROUP_RECORDS ORCA_REGISTER_NODE ORCA_REGISTER_RPC_MODULE
fi

# --- the 90-src script ORDER is load-bearing, so assert it ------------------
#
# chezmoi strips run_/before_/after_/onchange_ and .tmpl before sorting
# same-phase scripts, so the remaining basename decides which runs first.
# Registration must run AFTER the reconciler grows the trees, or a newly
# declared tree registers only on the second apply. The earlier name
# `orca-register` sorted before `reconcile-garden` and had exactly that bug.
# A comment cannot stop a rename; this can.

strip_attrs() {
  printf '%s' "${1##*/}" |
    sed -e 's/\.tmpl$//' -e 's/^run_//' \
        -e 's/^once_//' -e 's/^onchange_//' \
        -e 's/^before_//' -e 's/^after_//'
}

# A glob loop, not `ls | grep`: shellcheck rejects the latter (SC2010) and a
# non-matching glob would otherwise abort this file's own `set -euo pipefail`.
reconcile_script=''
register_script=''
for candidate in "$repo_root"/.chezmoiscripts/90-src/*; do
  [ -e "$candidate" ] || continue
  case "${candidate##*/}" in
    *reconcile-garden*) [ -n "$reconcile_script" ] || reconcile_script=$candidate ;;
    *register-orca*|*orca-register*) [ -n "$register_script" ] || register_script=$candidate ;;
  esac
done
[ -n "$reconcile_script" ] || fail 'no 90-src reconcile-garden script found'
[ -n "$register_script" ] || fail 'no 90-src Orca registration script found'

reconcile_sort=$(strip_attrs "$reconcile_script")
register_sort=$(strip_attrs "$register_script")
first=$(printf '%s\n%s\n' "$reconcile_sort" "$register_sort" | LC_ALL=C sort | head -n 1)
[ "$first" = "$reconcile_sort" ] || fail "90-src ordering inverted: '$register_sort' sorts before '$reconcile_sort', so registration runs before the trees are grown and a newly declared tree registers only on the second apply"
pass 'the Orca registration script sorts after the garden reconciler'

printf 'test-orca-register: all checks passed\n'
