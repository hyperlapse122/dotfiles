#!/usr/bin/env bash
# Guards the SessionStart hook this checkout ships to Codex
# (dot_local/share/dotfiles-codex-plugin/hooks/executable_orchestration.sh.tmpl),
# its configuration (dot_local/share/dotfiles-codex-plugin/hooks/hooks.json),
# and its pre-seeded trust record (.chezmoitemplates/codex-hook-trust.tmpl).
#
# Contracts tested:
#   1. The role table: lead and worker both produce the everyone-payload,
#      none produces no output at all.
#   2. hooks.json uses the event key SessionStart, registers exactly the four
#      Codex sources (startup, resume, clear, compact), contains no fork, and
#      sets additionalContextLimit to 0.
#   3. The hook reads stdin to a bound and exits zero promptly even when the
#      stdin writer never closes the pipe.
#   4. Every failure path prints nothing at all rather than stray text, because
#      Codex treats plain non-JSON stdout as model context verbatim.
#   5. The trust record computes the expected key and sha256 hash.
#   6. The trust key and hash are independent from the plugin's derived version.
#   7. Every external tool is stubbed so no live app or live HOME is reached.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
hook_tmpl="$repo_root/dot_local/share/dotfiles-codex-plugin/hooks/executable_orchestration.sh.tmpl"
hooks_json="$repo_root/dot_local/share/dotfiles-codex-plugin/hooks/hooks.json"
everyone_payload_tmpl="$repo_root/dot_local/share/dotfiles-codex-plugin/payloads/readonly_everyone.md.tmpl"
plugin_manifest_tmpl="$repo_root/dot_local/share/dotfiles-codex-plugin/dot_codex-plugin/plugin.json.tmpl"
trust_tmpl="$repo_root/.chezmoitemplates/codex-hook-trust.tmpl"

fail() { printf 'codex orchestration hook: %s\n' "$*" >&2; exit 1; }
pass() { printf 'codex orchestration hook: %s\n' "$*"; }

[[ -f $hook_tmpl ]] || fail "missing hook template $hook_tmpl"
[[ -f $hooks_json ]] || fail "missing $hooks_json"
[[ -f $everyone_payload_tmpl ]] || fail "missing $everyone_payload_tmpl"
[[ -f $plugin_manifest_tmpl ]] || fail "missing $plugin_manifest_tmpl"
[[ -f $trust_tmpl ]] || fail "missing $trust_tmpl"

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/codex-orchestration-hook
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

mkdir -p "$scratch/bin" "$scratch/op-bin" "$scratch/target" "$scratch/home"

# The hook runs in a clean scratch environment. Find a real jq binary outside
# any version-manager shims so PATH stubs don't break.
jq_bin=''
IFS=: read -r -a path_entries <<<"$PATH"
for entry in "${path_entries[@]}"; do
  [[ -n $entry && $entry != *"/shims"* ]] || continue
  if [[ -x "$entry/jq" ]]; then
    jq_bin="$entry/jq"
    break
  fi
done
[[ -n $jq_bin ]] || fail 'no jq binary outside a version-manager shim directory is on PATH'
ln -sf -- "$jq_bin" "$scratch/bin/jq"

# Provide only what the hook needs: bash, head (for drain_stdin), and dirname
for tool in bash head dirname; do
  tool_path=$(command -v "$tool") || fail "the hook needs $tool and it is not on PATH"
  ln -sf -- "$tool_path" "$scratch/bin/$tool"
done

chezmoi_bin=$(command -v chezmoi || true)
[[ -n $chezmoi_bin ]] || fail 'no chezmoi binary found on PATH'

# Stub op and empty config so execute-template never touches live 1Password
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$scratch/op-bin/op"
chmod 0700 -- "$scratch/op-bin/op"
printf '[data]\n' > "$scratch/empty.toml"

render_tmpl() {
  local tmpl=$1 out=$2
  env HOME="$scratch/home" PATH="$scratch/op-bin:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" \
      --destination "$scratch/target" execute-template <"$tmpl" >"$out"
}

render_inline() {
  local tmpl_code=$1
  env HOME="$scratch/home" PATH="$scratch/op-bin:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" \
      --destination "$scratch/target" execute-template <<<"$tmpl_code"
}

plugin_root="$scratch/plugin-root"
mkdir -p "$plugin_root/hooks" "$plugin_root/payloads"
hook="$plugin_root/hooks/orchestration.sh"
render_tmpl "$hook_tmpl" "$hook"
chmod 0700 -- "$hook"
render_tmpl "$everyone_payload_tmpl" "$plugin_root/payloads/everyone.md"

run_hook_in() {
  local bindir=$1
  shift
  env -i \
    PATH="$scratch/$bindir:$scratch/bin" \
    CLAUDE_PLUGIN_ROOT="$plugin_root" \
    "$@" \
    "$scratch/bin/bash" "$hook"
}
run_hook() { run_hook_in bin "$@"; }

context_of() {
  "$jq_bin" -er '.hookSpecificOutput.additionalContext' 2>/dev/null
}

# --- 1. hooks.json schema, event, matcher, and limit assertions ---
[[ $("$jq_bin" -r '.hooks | keys | length' <"$hooks_json") -eq 1 ]] ||
  fail 'hooks.json declares more than one event category'
[[ $("$jq_bin" -r '.hooks | has("SessionStart")' <"$hooks_json") == true ]] ||
  fail 'hooks.json does not declare the SessionStart event'
[[ $("$jq_bin" -r '.hooks.SessionStart | length' <"$hooks_json") -eq 1 ]] ||
  fail 'hooks.json declares more than one SessionStart matcher group'

matcher=$("$jq_bin" -r '.hooks.SessionStart[0].matcher' <"$hooks_json")
for source in startup resume clear compact; do
  [[ $matcher == *"$source"* ]] || fail "hooks.json matcher does not register the $source source: $matcher"
done
[[ $matcher == 'startup|resume|clear|compact' ]] ||
  fail "hooks.json matcher is '$matcher', not the exact declared 4-source expression"
[[ $matcher != *"fork"* ]] || fail 'hooks.json matcher unexpectedly registers fork'

if grep -qi 'fork' "$hooks_json"; then
  fail 'hooks.json contains fork, which is not supported on Codex'
fi

[[ $("$jq_bin" -r '.hooks.SessionStart[0].hooks | length' <"$hooks_json") -eq 1 ]] ||
  fail 'hooks.json declares more than one hook under SessionStart'

declared_type=$("$jq_bin" -r '.hooks.SessionStart[0].hooks[0].type' <"$hooks_json")
[[ $declared_type == 'command' ]] || fail "declared hook type is '$declared_type', expected command"

limit=$("$jq_bin" -r '.hooks.SessionStart[0].hooks[0].additionalContextLimit' <"$hooks_json")
[[ $limit == '0' ]] || fail "hooks.json additionalContextLimit is '$limit', expected 0"

declared_cmd=$("$jq_bin" -r '.hooks.SessionStart[0].hooks[0].command' <"$hooks_json")
[[ $declared_cmd == '"${CLAUDE_PLUGIN_ROOT}"/hooks/orchestration.sh' ]] ||
  fail "hooks.json command is '$declared_cmd', unexpected path"

pass 'hooks.json uses event SessionStart, lists 4 sources without fork, and sets additionalContextLimit: 0'

# --- 2. Prompt exit on unclosed stdin pipe ---
# The hook reads stdin to a 64 KiB bound and exits promptly without waiting
# for EOF from a producer that keeps the write end open.
start_time=$SECONDS
pipe_out=$( (yes '{"hook_event_name":"SessionStart"}' 2>/dev/null || true) | run_hook ORCA_TERMINAL_HANDLE=term_1 TMUX_PANE=%1 ) ||
  fail 'hook with unclosed stdin producer exited non-zero'
pipe_elapsed=$((SECONDS - start_time))
(( pipe_elapsed <= 2 )) ||
  fail "hook took ${pipe_elapsed}s on an unclosed pipe; expected prompt exit <= 2s"
pipe_ctx=$(printf '%s' "$pipe_out" | context_of) ||
  fail 'hook with unclosed stdin producer emitted no additionalContext'
[[ $pipe_ctx == *"<!-- orchestration-everyone:end -->"* ]] ||
  fail 'hook with unclosed stdin producer did not output the everyone payload'
pass 'the hook reads stdin and exits zero promptly without waiting on an unclosed producer'

# --- 3. The role table ---
# Codex carries no lead branch: lead-shaped and worker-shaped Orca sessions both
# deliver the everyone-payload; non-Orca sessions produce no output at all.

# 3a. Lead shape: ORCA_TERMINAL_HANDLE set, lead pane equals TMUX_PANE
out_lead=$(run_hook ORCA_TERMINAL_HANDLE=term_1 TMUX_PANE=%1 ORCA_AGENT_TEAMS_LEADER_PANE=%1) ||
  fail 'lead-shaped run exited non-zero'
ctx_lead=$(printf '%s' "$out_lead" | context_of) ||
  fail 'lead-shaped run emitted no additionalContext'
[[ $ctx_lead == *"<!-- orchestration-everyone:begin -->"* ]] ||
  fail 'lead-shaped run missing everyone begin sentinel'
[[ $ctx_lead == *"<!-- orchestration-everyone:end -->"* ]] ||
  fail 'lead-shaped run missing everyone end sentinel'
last_line_lead=$(printf '%s' "$ctx_lead" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | tail -n 1)
[[ $last_line_lead == '<!-- orchestration-everyone:end -->' ]] ||
  fail "lead-shaped run did not end with everyone sentinel line: '$last_line_lead'"
[[ $ctx_lead != *"orchestration-coordinator"* ]] ||
  fail 'lead-shaped run unexpectedly contains coordinator sentinel'
[[ $ctx_lead != *"GUIDE BODY MARKER"* ]] ||
  fail 'lead-shaped run unexpectedly contains guide body marker'
[[ $ctx_lead != *"SKILL BODY MARKER"* ]] ||
  fail 'lead-shaped run unexpectedly contains skill body marker'

# 3b. Worker shape (no lead pane variable)
out_w1=$(run_hook ORCA_TERMINAL_HANDLE=term_1 TMUX_PANE=%1) ||
  fail 'worker (no lead pane) exited non-zero'
ctx_w1=$(printf '%s' "$out_w1" | context_of) ||
  fail 'worker (no lead pane) emitted no additionalContext'
[[ $ctx_w1 == *"<!-- orchestration-everyone:end -->"* ]] ||
  fail 'worker (no lead pane) missing everyone end sentinel'
[[ $ctx_w1 != *"orchestration-coordinator"* ]] ||
  fail 'worker (no lead pane) unexpectedly contains coordinator sentinel'

# 3c. Worker shape (lead pane differs from TMUX_PANE)
out_w2=$(run_hook ORCA_TERMINAL_HANDLE=term_1 TMUX_PANE=%2 ORCA_AGENT_TEAMS_LEADER_PANE=%1) ||
  fail 'worker (unequal pane) exited non-zero'
ctx_w2=$(printf '%s' "$out_w2" | context_of) ||
  fail 'worker (unequal pane) emitted no additionalContext'
[[ $ctx_w2 == *"<!-- orchestration-everyone:end -->"* ]] ||
  fail 'worker (unequal pane) missing everyone end sentinel'
[[ $ctx_w2 != *"orchestration-coordinator"* ]] ||
  fail 'worker (unequal pane) unexpectedly contains coordinator sentinel'
# 3d. None shape: empty handle with matching lead pane -> no output
out_none1=$(run_hook ORCA_TERMINAL_HANDLE='' TMUX_PANE=%1 ORCA_AGENT_TEAMS_LEADER_PANE=%1) ||
  fail 'empty-handle run exited non-zero'
[[ -z $out_none1 ]] || fail "empty-handle run emitted '$out_none1', expected no output"

# 3e. None shape: unset handle with matching lead pane -> no output
out_none2=$(run_hook TMUX_PANE=%1 ORCA_AGENT_TEAMS_LEADER_PANE=%1) ||
  fail 'unset-handle run exited non-zero'
[[ -z $out_none2 ]] || fail "unset-handle run emitted '$out_none2', expected no output"

# 3f. None shape: bare session with no env vars -> no output
out_none3=$(run_hook) || fail 'bare non-Orca run exited non-zero'
[[ -z $out_none3 ]] || fail "bare non-Orca run emitted '$out_none3', expected no output"

pass 'the role table: lead and worker both produce everyone-payload; none produces no output'

# --- 4. Failure paths emit nothing at all ---
# Codex treats plain stdout as model context verbatim, so a failure or no-op path
# must emit 0 bytes rather than error messages or partial lines.

# 4a. Missing everyone-payload file
mkdir -p "$scratch/missing-plugin/hooks"
cp -- "$hook" "$scratch/missing-plugin/hooks/orchestration.sh"
out_err1=$(env -i PATH="$scratch/bin" ORCA_TERMINAL_HANDLE=term_1 "$scratch/bin/bash" "$scratch/missing-plugin/hooks/orchestration.sh") ||
  fail 'missing-payload run exited non-zero'
[[ -z $out_err1 ]] || fail "missing-payload run emitted stray output: '$out_err1'"

# 4b. Unreadable everyone-payload file
mkdir -p "$scratch/unreadable-plugin/hooks" "$scratch/unreadable-plugin/payloads"
cp -- "$hook" "$scratch/unreadable-plugin/hooks/orchestration.sh"
touch "$scratch/unreadable-plugin/payloads/everyone.md"
chmod 0000 "$scratch/unreadable-plugin/payloads/everyone.md"
out_err2=$(env -i PATH="$scratch/bin" ORCA_TERMINAL_HANDLE=term_1 "$scratch/bin/bash" "$scratch/unreadable-plugin/hooks/orchestration.sh") ||
  fail 'unreadable-payload run exited non-zero'
[[ -z $out_err2 ]] || fail "unreadable-payload run emitted stray output: '$out_err2'"
chmod 0600 "$scratch/unreadable-plugin/payloads/everyone.md"

# 4c. Missing jq on PATH
mkdir -p "$scratch/no-jq-bin"
for tool in bash head dirname; do
  ln -sf -- "$(command -v "$tool")" "$scratch/no-jq-bin/$tool"
done
out_err3=$(env -i PATH="$scratch/no-jq-bin" ORCA_TERMINAL_HANDLE=term_1 "$scratch/bin/bash" "$hook") ||
  fail 'missing-jq run exited non-zero'
[[ -z $out_err3 ]] || fail "missing-jq run emitted stray output: '$out_err3'"

# 4d. Unresolvable plugin root without CLAUDE_PLUGIN_ROOT
cp -- "$hook" "$scratch/unrooted-hook.sh"
out_err4=$(env -i PATH="$scratch/bin" ORCA_TERMINAL_HANDLE=term_1 "$scratch/bin/bash" "$scratch/unrooted-hook.sh") ||
  fail 'unrooted hook run exited non-zero'
[[ -z $out_err4 ]] || fail "unrooted hook run emitted stray output: '$out_err4'"

pass 'failure paths emit nothing at all and exit zero'

# --- 5. The trust record ---
# Render .chezmoitemplates/codex-hook-trust.tmpl and verify the exact key and hash.
expected_trust_key="dotfiles-codex@dotfiles:hooks/hooks.json:session_start:0:0"
expected_trust_hash="sha256:f0e71f6f167e87739d4c897ad644325ec87816d2c026301f54337bda4fbb73f8"

trust_json=$(render_inline '{{ includeTemplate "codex-hook-trust.tmpl" (dict "ctx" .) }}')
actual_trust_key=$(printf '%s' "$trust_json" | "$jq_bin" -r '.state | keys[0]')
actual_trust_hash=$(printf '%s' "$trust_json" | "$jq_bin" -r --arg k "$actual_trust_key" '.state[$k].trusted_hash')

[[ $actual_trust_key == "$expected_trust_key" ]] ||
  fail "trust key is '$actual_trust_key', expected '$expected_trust_key'"
[[ $actual_trust_hash == "$expected_trust_hash" ]] ||
  fail "trust hash is '$actual_trust_hash', expected '$expected_trust_hash'"

pass "trust record key matches '$expected_trust_key' with expected sha256 hash"

# --- 6. Independence from plugin version ---
# Changing the plugin's derived version must leave the trust key and hash unchanged.
# plugin.json.tmpl hashes all files in dot_local/share/dotfiles-codex-plugin, so
# adding or modifying a file in the plugin directory moves its derived version.
# The trust key and hash, however, attest only the normalized hook declaration.

# Derive initial plugin version
orig_version=$(render_tmpl "$plugin_manifest_tmpl" /dev/stdout | "$jq_bin" -r '.version')

# Build a lightweight symlink farm of the repo with a modified file in the codex plugin
bump_scratch="$scratch/repo-bump"
mkdir -p "$bump_scratch"
for entry in "$repo_root"/* "$repo_root"/.*; do
  entry_name=$(basename "$entry")
  [[ $entry_name == "." || $entry_name == ".." || $entry_name == "dot_local" ]] && continue
  ln -sf -- "$entry" "$bump_scratch/$entry_name"
done
mkdir -p "$bump_scratch/dot_local/share"
for entry in "$repo_root/dot_local/share"/*; do
  entry_name=$(basename "$entry")
  [[ $entry_name == "dotfiles-codex-plugin" ]] && continue
  ln -sf -- "$entry" "$bump_scratch/dot_local/share/$entry_name"
done
cp -r "$repo_root/dot_local/share/dotfiles-codex-plugin" "$bump_scratch/dot_local/share/dotfiles-codex-plugin"

# Add a dummy file to change the plugin's content hash
printf 'simulated content change to bump version\n' > "$bump_scratch/dot_local/share/dotfiles-codex-plugin/dummy_bump.txt"

bumped_version=$(env HOME="$scratch/home" PATH="$scratch/op-bin:/usr/bin:/bin" \
  "$chezmoi_bin" --config "$scratch/empty.toml" --source "$bump_scratch" \
    --destination "$scratch/target" execute-template < "$bump_scratch/dot_local/share/dotfiles-codex-plugin/dot_codex-plugin/plugin.json.tmpl" | "$jq_bin" -r '.version')

[[ -n $bumped_version && $bumped_version != "$orig_version" ]] ||
  fail "plugin version did not move: orig='$orig_version', bumped='$bumped_version'"

bumped_trust_json=$(env HOME="$scratch/home" PATH="$scratch/op-bin:/usr/bin:/bin" \
  "$chezmoi_bin" --config "$scratch/empty.toml" --source "$bump_scratch" \
    --destination "$scratch/target" execute-template <<<'{{ includeTemplate "codex-hook-trust.tmpl" (dict "ctx" .) }}')

bumped_trust_key=$(printf '%s' "$bumped_trust_json" | "$jq_bin" -r '.state | keys[0]')
bumped_trust_hash=$(printf '%s' "$bumped_trust_json" | "$jq_bin" -r --arg k "$bumped_trust_key" '.state[$k].trusted_hash')

[[ $bumped_trust_key == "$expected_trust_key" ]] ||
  fail "after version bump, trust key changed to '$bumped_trust_key'"
[[ $bumped_trust_hash == "$expected_trust_hash" ]] ||
  fail "after version bump, trust hash changed to '$bumped_trust_hash'"

pass "changing plugin version ($orig_version -> $bumped_version) leaves trust key and hash unchanged"
