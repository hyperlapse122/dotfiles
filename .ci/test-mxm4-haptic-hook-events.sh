#!/usr/bin/env bash
# Hermetic MX Master 4 haptic hook event tests (Claude Code + Codex).
#
# Renders the PRODUCTION hook manifests (dot_local/share/*-plugins/mxm4-haptic/
# hooks/hooks.json.tmpl) for POSIX hosts, extracts each event's command from the
# rendered JSON, and executes it exactly the way the agent runtime would —
# event JSON on stdin, plugin root in the environment — against a stub
# mxm4-haptic client that records its argv. No hardware, no daemon, no live
# services: the client is the delivery boundary, so recording its invocation
# proves the full hook -> wrapper -> client path.
#
# Asserts per event:
#   1. the stub client receives exactly the haptic.yaml-configured waveform;
#   2. the hook exits 0 and prints nothing (the always-silent contract);
#   3. a missing client and a failing client are both silent no-ops.
#
# Windows renders (pulse.ps1 / inline PowerShell) are covered by render
# assertions in test-mxm4-haptic-gates.sh; this test exercises the POSIX hook
# path shared by Linux and macOS.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixtures="$repo_root/.ci/fixtures/mxm4-haptic"
scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/mxm4-haptic-hooks.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/target" "$scratch/bin"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod +x "$scratch/bin/op"
chezmoi_bin=$(type -P chezmoi)

fail() { printf 'mxm4-haptic hook events: %s\n' "$*" >&2; exit 1; }

render() {
  local os=$1 input=$2 output=$3
  env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" \
      --destination "$scratch/target" --override-data "{\"chezmoi\":{\"os\":\"$os\"}}" \
      execute-template <"$input" >"$output"
}

extract_command() {
  local manifest=$1 event=$2
  node - "$manifest" "$event" <<'NODE'
const fs = require('node:fs');
const [manifest, event] = process.argv.slice(2);
const parsed = JSON.parse(fs.readFileSync(manifest, 'utf8'));
const entries = parsed.hooks?.[event];
if (!Array.isArray(entries) || entries.length !== 1) throw new Error(`unexpected hook entries for ${event}`);
const commands = entries[0].hooks.filter((hook) => hook.type === 'command').map((hook) => hook.command);
if (commands.length !== 1) throw new Error(`expected exactly one command hook for ${event}`);
process.stdout.write(commands[0]);
NODE
}

# The stub client stands in for the deployed ~/.local/bin/mxm4-haptic: it
# records its argv (one line per pulse) and exits per FIXTURE mode.
home="$scratch/home"
record="$scratch/record"
: >"$record"
plugin_root="$scratch/claude-plugin"
mkdir -p "$plugin_root/bin"
cp "$repo_root/dot_local/share/claude-plugins/mxm4-haptic/bin/executable_pulse" \
  "$plugin_root/bin/pulse"
chmod 700 "$plugin_root/bin/pulse"
install_stub() {
  local mode=$1
  mkdir -p "$home/.local/bin"
  cat >"$home/.local/bin/mxm4-haptic" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MXM4_HAPTIC_RECORD"
STUB
  chmod +x "$home/.local/bin/mxm4-haptic"
  if [[ "$mode" == fail ]]; then
    printf 'exit 1\n' >>"$home/.local/bin/mxm4-haptic"
  fi
}

# run_hook MANIFEST EVENT FIXTURE EXPECTED — execute the event's rendered
# command against the stub and require the exact waveform, exit 0, no output.
run_hook() {
  local manifest=$1 event=$2 fixture=$3 expected=$4
  local command before stdout rc
  command=$(extract_command "$manifest" "$event") || fail "cannot extract $event command from $manifest"
  before=$(wc -l <"$record")
  stdout="$scratch/stdout"
  rc=0
  CLAUDE_PLUGIN_ROOT="$plugin_root" \
  HOME="$home" MXM4_HAPTIC_RECORD="$record" PATH="$scratch/bin:/usr/bin:/bin" \
    sh -c "$command" <"$fixture" >"$stdout" 2>"$scratch/stderr" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "$event hook exited $rc (contract: always 0)"
  [[ ! -s "$stdout" ]] || fail "$event hook printed to stdout (contract: always silent)"
  [[ $(wc -l <"$record") -eq $((before + 1)) ]] || fail "$event hook did not pulse the client exactly once"
  [[ $(tail -1 "$record") == "$expected" ]] || fail "$event pulsed '$(tail -1 "$record")', expected '$expected'"
}

# run_silent MANIFEST EVENT — with no client anywhere, the hook must still
# exit 0, print nothing, and record no pulse.
run_silent() {
  local manifest=$1 event=$2
  local command before rc=0
  command=$(extract_command "$manifest" "$event")
  before=$(wc -l <"$record")
  CLAUDE_PLUGIN_ROOT="$plugin_root" \
  HOME="$home" MXM4_HAPTIC_RECORD="$record" PATH="$scratch/bin:/usr/bin:/bin" \
    sh -c "$command" </dev/null >"$scratch/stdout" 2>"$scratch/stderr" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "$event hook without a client exited $rc"
  [[ ! -s "$scratch/stdout" ]] || fail "$event hook without a client printed to stdout"
  [[ $(wc -l <"$record") -eq "$before" ]] || fail "$event hook without a client still recorded a pulse"
}

claude_tmpl="$repo_root/dot_local/share/claude-plugins/mxm4-haptic/hooks/hooks.json.tmpl"
codex_tmpl="$repo_root/dot_local/share/codex-plugins/mxm4-haptic/hooks/hooks.json.tmpl"

for os in linux darwin; do
  claude_hooks="$scratch/hooks-claude-$os.json"
  codex_hooks="$scratch/hooks-codex-$os.json"
  render "$os" "$claude_tmpl" "$claude_hooks"
  render "$os" "$codex_tmpl" "$codex_hooks"

  install_stub ok
  # haptic.yaml defaults: claude stop COMPLETED / stopFailure MAD /
  # notification RINGING / question RINGING; codex settled COMPLETED /
  # question RINGING.
  run_hook "$claude_hooks" Stop "$fixtures/claude-stop.json" COMPLETED
  run_hook "$claude_hooks" StopFailure "$fixtures/claude-stop.json" MAD
  run_hook "$claude_hooks" Notification "$fixtures/claude-stop.json" RINGING
  run_hook "$claude_hooks" PreToolUse "$fixtures/claude-question.json" RINGING
  run_hook "$codex_hooks" Stop "$fixtures/codex-stop.json" COMPLETED
  run_hook "$codex_hooks" PermissionRequest "$fixtures/codex-permission-request.json" RINGING

  # Delivery failures stay silent: no client at all, then a failing client.
  rm -f "$home/.local/bin/mxm4-haptic"
  run_silent "$claude_hooks" Stop
  run_silent "$codex_hooks" PermissionRequest
  install_stub fail
  before=$(wc -l <"$record")
  rc=0
  CLAUDE_PLUGIN_ROOT="$plugin_root" \
  HOME="$home" MXM4_HAPTIC_RECORD="$record" PATH="$scratch/bin:/usr/bin:/bin" \
    sh -c "$(extract_command "$claude_hooks" Stop)" </dev/null >"$scratch/stdout" 2>"$scratch/stderr" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "$os claude hook propagated a client failure (exit $rc)"
  [[ ! -s "$scratch/stdout" ]] || fail "$os claude hook with a failing client printed to stdout"
  [[ $(wc -l <"$record") -eq $((before + 1)) ]] || fail "$os claude hook never reached the failing client"
done

printf '%s\n' 'mxm4-haptic hook event tests passed'
