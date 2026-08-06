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
trap 'rm -rf -- "$scratch"' EXIT
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
# extension resolution -- but unlike step 4 it needs no model credentials, so
# it runs on every CI run and is the standing floor for KTD1's no-build claim.
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
# once against a managed one (must not). This needs a real model turn, so it
# is the one assertion gated on model credentials being present; every
# assertion above and the real-HOME-untouched check below always run.
credential_vars=(ANTHROPIC_API_KEY ANTHROPIC_OAUTH_TOKEN OPENAI_API_KEY OPENROUTER_API_KEY OPENCODE_API_KEY GEMINI_API_KEY)
have_model_credentials=0
for var in "${credential_vars[@]}"; do
  if [[ -n ${!var:-} ]]; then
    have_model_credentials=1
    break
  fi
done

if [[ $have_model_credentials -eq 1 ]]; then
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

  prompt='Run exactly one bash tool call: `gh issue create --repo other-owner/other-repo --title "test issue" --body "test body"`. Do not run any other command, and do not retry through a different tool or CLI. Report verbatim whatever output or error that single command produces.'

  run_omp_prompt() {
    (
      cd "$workdir" &&
        env -u PI_CODING_AGENT_DIR -u OMP_AGENT_ENV \
          HOME="$home" USERPROFILE="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
          PATH="$gh_stub:$PATH" GH_LOG="$1" GH_REPO_VIEW_JSON="$2" GH_LOGIN='ci-test-user' \
          omp -p "$prompt" --auto-approve --no-session --max-time 120
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
else
  printf 'test-unmanaged-repo-guard-real: SKIP the real-model tool-call block/allow proof (U8 step 4) - no model credentials found in any of: %s. The unconditional step 3b load proof, install, enable, list, lock-shape, and real-HOME-untouched assertions all still ran.\n' \
    "${credential_vars[*]}" >&2
  # Surface the gap in the Checks UI rather than burying it in step logs: this
  # is the one assertion that exercises omp's own extension resolution, so a
  # green run without it proves strictly less than a green run with it.
  if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    printf '::warning title=unmanaged-repo-guard::U8 step 4 (real-omp runtime block proof) was skipped: no model credentials in CI. Plugin install/enable/load were verified; omp runtime dispatch through the guard was not.\n'
  fi
fi

real_lock_after=$(snapshot_real_lock)
[[ $real_lock_before == "$real_lock_after" ]] ||
  fail "real \$HOME plugin lock changed during the run: $real_lock"

if [[ $have_model_credentials -eq 1 ]]; then
  printf 'real OMP unmanaged-repo-guard: install, enable, lock, raw-.ts load, and omp-runtime block/allow proof passed\n'
else
  printf 'real OMP unmanaged-repo-guard: install, enable, lock, and raw-.ts load passed; omp-runtime block/allow proof SKIPPED (see warning above)\n'
fi
