#!/usr/bin/env bash
set -euo pipefail

# Real-omp install/enable/runtime proof for the unmanaged-repo-guard plugin
# (plan U8). Modeled on test-omp-real-plugin.sh: version-pinned omp, a
# relocated HOME so nothing escapes the real one, and a scratch marketplace
# built from the already-rendered package this script receives as $1.
#
# Step 4 below is the load-bearing assertion (U8's "Execution note"): it
# drives a real tool call through omp's OWN runtime against a stubbed `gh`,
# proving omp resolves the manifest's raw `./src/index.ts` entry and that the
# guard's `{ block: true, reason }` return actually stops the bash tool. A
# `bun` import of the entry file would only prove the module parses, which
# U8 explicitly forbids substituting here (KTD1's regression detector).
#
# U8's "Detection limit, stated honestly" applies: CI pins the omp version,
# so this re-confirms known-good raw-.ts resolution and only catches a
# regression on the run that bumps the pin.

usage='usage: test-unmanaged-repo-guard-real.sh RENDERED_PACKAGE_DIR'
package_dir=${1:?$usage}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'test-unmanaged-repo-guard-real: %s\n' "$*" >&2
  exit 1
}

skip() {
  printf 'test-unmanaged-repo-guard-real: SKIP - %s\n' "$*" >&2
  exit 0
}

command -v omp >/dev/null 2>&1 || skip 'omp is not on PATH'
command -v bun >/dev/null 2>&1 || skip 'bun is not on PATH'
command -v jq >/dev/null 2>&1 || skip 'jq is not on PATH'

[[ -f $package_dir/package.json && -f $package_dir/src/index.ts ]] ||
  fail "rendered guard package is incomplete: $package_dir"

locked_version=$(jq -er '.releases.tools.omp.version | sub("^v"; "")' "$repo_root/.chezmoidata/releases.json")
version_pattern=${locked_version//./\\.}
[[ $(omp --version) =~ (^|[^[:digit:]])${version_pattern}([^[:digit:]]|$) ]] ||
  fail "omp on PATH does not match locked version $locked_version"

# Snapshot the real $HOME plugin lock before touching anything, so the final
# assertion can prove nothing in this script ever escaped the relocated HOME
# below - not the install, not the runtime -p run.
real_lock="$HOME/.omp/plugins/omp-plugins.lock.json"
snapshot_real_lock() {
  if [[ -f $real_lock ]]; then
    sha256sum -- "$real_lock" | awk '{print $1}'
  else
    printf 'absent'
  fi
}
real_lock_before=$(snapshot_real_lock)

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/omp-unmanaged-repo-guard-real
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/smoke.XXXXXX")
trap 'kill "${stub_pid:-}" 2>/dev/null || true; rm -rf -- "$scratch"' EXIT
home="$scratch/home"
marketplace="$scratch/marketplace"
workdir="$scratch/workdir"
mkdir -p "$home" "$workdir" "$marketplace/.omp-plugin" "$marketplace/plugins"
cp -R -- "$package_dir" "$marketplace/plugins/unmanaged-repo-guard"
cat >"$marketplace/.omp-plugin/marketplace.json" <<'JSON'
{"name":"h82-dotfiles","owner":{"name":"test"},"plugins":[{"name":"unmanaged-repo-guard","source":"./plugins/unmanaged-repo-guard"}]}
JSON

run_omp() {
  (
    cd "$workdir" &&
      env -u PI_CODING_AGENT_DIR -u OMP_AGENT_ENV \
        HOME="$home" USERPROFILE="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
        omp "$@"
  )
}

run_omp plugin marketplace add "$marketplace"
run_omp plugin install --scope user --force unmanaged-repo-guard@h82-dotfiles
run_omp plugin enable --scope user unmanaged-repo-guard@h82-dotfiles
run_omp plugin list >"$scratch/list.out"
grep -F 'unmanaged-repo-guard' "$scratch/list.out" >/dev/null ||
  fail 'omp plugin list did not name unmanaged-repo-guard'

installed="$home/.omp/plugins/installed_plugins.json"
lock="$home/.omp/plugins/omp-plugins.lock.json"
jq -e '
  .plugins["unmanaged-repo-guard@h82-dotfiles"] as $rows
  | ($rows | type) == "array"
    and ($rows | length) == 1
    and $rows[0].scope == "user"
    and ($rows[0].installPath | type) == "string"
' "$installed" >/dev/null
jq -e '.plugins["@h82/omp-unmanaged-repo-guard"].enabled == true' "$lock" >/dev/null
install_root=$(jq -er '.plugins["unmanaged-repo-guard@h82-dotfiles"][0].installPath' "$installed")
case $install_root in
  "$home"/*) ;;
  *) fail "installed plugin escaped relocated HOME: $install_root" ;;
esac

# Step 3b (unconditional): prove the INSTALLED raw .ts entry parses and
# registers exactly one tool_call handler under Bun, the same runtime omp
# embeds. This is a weaker tier than step 4 -- it does not exercise omp's own
# extension resolution -- but it runs with no omp runtime turn at all, and is
# the standing floor for KTD1's no-build claim.
entry="$install_root/src/index.ts"
[[ -f $entry ]] || fail "installed plugin has no src/index.ts entry: $entry"
bun - "$entry" <<'BUN' || fail 'installed raw .ts entry failed to load and register'
const entry = process.argv[2];
const events = [];
const pi = new Proxy(
  {
    exec: async () => ({ stdout: "", stderr: "", code: 0, killed: false }),
    on: (event) => events.push(event),
    logger: { error: () => {} },
  },
  {
    get(target, prop) {
      if (prop in target) return target[prop];
      throw new Error(`extension touched unexpected pi API: ${String(prop)}`);
    },
  },
);
const mod = await import(entry);
if (typeof mod.default !== "function") throw new Error("entry has no default factory");
mod.default(pi);
if (events.length !== 1 || events[0] !== "tool_call") {
  throw new Error(`expected exactly one tool_call registration, got ${JSON.stringify(events)}`);
}
BUN

# Step 4 (load-bearing): drive one real bash tool call through omp's own
# runtime, twice - once against an unmanaged stub verdict (must block) and
# once against a managed one (must not). Model turns are served by a local
# keyless stub provider (KTD5): a models.yml `auth: none` provider backed by
# .ci/lib/stub-model-server.ts on 127.0.0.1. This needs no model credential,
# so the proof runs unconditionally on every CI run.
# The proof must reach the loopback stub, never a real provider. Rather than
# refusing to run when the invoking shell happens to carry a provider key - a
# developer workstation usually does - strip the whole set from the child
# environment below, so the omp process tree cannot authenticate anywhere even
# when the caller could. Consumed by run_omp_prompt.
omp_credential_vars=(ANTHROPIC_API_KEY ANTHROPIC_OAUTH_TOKEN OPENAI_API_KEY OPENROUTER_API_KEY OPENCODE_API_KEY GEMINI_API_KEY)
unset_credentials=()
for var in "${omp_credential_vars[@]}"; do
  unset_credentials+=(-u "$var")
done

gh_stub="$scratch/gh-stub"
mkdir -p "$gh_stub"
# Stubs the two gh shapes probe.ts actually issues: the identity lookup
# (`gh api --hostname <host> user --jq .login`) and the access probe
# (`gh repo view <target> --json viewerPermission,isFork,parent`). Logs
# every invocation so the assertions below can prove `issue create` did or
# did not reach the subprocess boundary.
cat >"$gh_stub/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
log=${GH_LOG:?GH_LOG unset}
printf 'GH_INVOKED:' >>"$log"
printf ' %q' "$@" >>"$log"
printf '\n' >>"$log"

if [[ ${1-} == repo && ${2-} == view ]]; then
  printf '%s' "$GH_REPO_VIEW_JSON"
  exit 0
fi
if [[ ${1-} == api ]]; then
  for arg in "$@"; do
    if [[ $arg == user ]]; then
      printf '%s' "$GH_LOGIN"
      exit 0
    fi
  done
  printf 'unhandled gh api invocation: %s\n' "$*" >&2
  exit 1
fi
if [[ ${1-} == issue && ${2-} == create ]]; then
  printf 'https://github.com/other-owner/other-repo/issues/999\n'
  exit 0
fi
printf 'unhandled gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$gh_stub/gh"

gh_command='gh issue create --repo other-owner/other-repo --title "test issue" --body "test body"'
prompt="Run exactly one bash tool call: \`$gh_command\`. Do not run any other command, and do not retry through a different tool or CLI. Report verbatim whatever output or error that single command produces."

# Stand up the stub model server that drives omp's own extension resolution
# (KTD5). It is torn down on any exit, including a failure, by the trap
# declared above.
stub_log="$scratch/stub-model-server.log"
: >"$stub_log"
stub_port_file="$scratch/stub-model-server.port"
stub_stderr_file="$scratch/stub-model-server.stderr"
tool_arguments=$(jq -cn --arg command "$gh_command" '{command: $command}')
bun "$repo_root/.ci/lib/stub-model-server.ts" "$stub_log" bash "$tool_arguments" \
  >"$stub_port_file" 2>"$stub_stderr_file" &
stub_pid=$!
for _ in $(seq 1 100); do
  [[ -s $stub_port_file ]] && break
  kill -0 "$stub_pid" 2>/dev/null ||
    fail "stub model server exited before printing its port: $(cat "$stub_stderr_file" 2>/dev/null)"
  sleep 0.1
done
[[ -s $stub_port_file ]] || fail 'stub model server never printed its port'
stub_port=$(<"$stub_port_file")

mkdir -p "$home/.omp/agent"
cat >"$home/.omp/agent/models.yml" <<YAML
providers:
  ci-stub:
    baseUrl: http://127.0.0.1:$stub_port/v1
    api: openai-completions
    auth: none
    models:
      - id: stub-1
        name: CI Stub
        contextWindow: 128000
        maxTokens: 4096
YAML

run_omp_prompt() {
  (
    cd "$workdir" &&
      env "${unset_credentials[@]}" -u PI_CODING_AGENT_DIR -u OMP_AGENT_ENV \
        HOME="$home" USERPROFILE="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
        PATH="$gh_stub:$PATH" GH_LOG="$1" GH_REPO_VIEW_JSON="$2" GH_LOGIN='ci-test-user' \
        NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 \
        omp -p "$prompt" --model ci-stub/stub-1 --auto-approve --no-session --max-time 120
  )
}

unmanaged_log="$scratch/gh-unmanaged.log"
set +e
unmanaged_out=$(run_omp_prompt "$unmanaged_log" '{"viewerPermission":"READ","isFork":false,"parent":null}' 2>&1)
unmanaged_status=$?
set -e
[[ $unmanaged_status -eq 0 ]] || fail "unmanaged-repo run exited $unmanaged_status: $unmanaged_out"
grep -qF 'a repository the user does not manage' <<<"$unmanaged_out" ||
  fail "blocked reason text missing from output: $unmanaged_out"
grep -qF 'other-owner/other-repo' <<<"$unmanaged_out" ||
  fail "blocked reason did not name the target repository: $unmanaged_out"
[[ -f $unmanaged_log ]] || fail 'unmanaged-repo run: gh probe never ran'
grep -qF 'issue create' "$unmanaged_log" &&
  fail 'unmanaged-repo run: gh issue create executed despite the block'

managed_log="$scratch/gh-managed.log"
set +e
managed_out=$(run_omp_prompt "$managed_log" '{"viewerPermission":"WRITE","isFork":false,"parent":null}' 2>&1)
managed_status=$?
set -e
[[ $managed_status -eq 0 ]] || fail "managed-repo run exited $managed_status: $managed_out"
grep -qF 'a repository the user does not manage' <<<"$managed_out" &&
  fail "managed-repo run was unexpectedly blocked: $managed_out"
[[ -f $managed_log ]] || fail 'managed-repo run: gh probe never ran'
grep -qF 'issue create' "$managed_log" ||
  fail 'managed-repo run: gh issue create never executed despite a managed verdict'

# A server that never saw a request would let the steps above pass
# vacuously, and a request that never offered `bash` would mean the tool
# list on the wire wasn't omp's own real one.
[[ -s $stub_log ]] ||
  fail 'stub model server was never contacted - the omp-runtime proof ran vacuously'
grep -qF '"bash"' "$stub_log" ||
  fail "stub model server never saw omp offer the bash tool: $(cat "$stub_log")"

real_lock_after=$(snapshot_real_lock)
[[ $real_lock_before == "$real_lock_after" ]] ||
  fail "real \$HOME plugin lock changed during the run: $real_lock"

printf 'real OMP unmanaged-repo-guard: install, enable, lock, raw-.ts load, and omp-runtime block/allow proof passed\n'
