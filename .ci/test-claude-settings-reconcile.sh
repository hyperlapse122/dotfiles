#!/usr/bin/env bash
# Guards the Claude Code settings reconciler: the render-time declaration guard
# (.chezmoitemplates/claude-settings-validate.tmpl) and the runtime leaf assertion
# (.chezmoiscripts/70-agents/run_after_config-claude-settings.sh.tmpl).
#
# The reconciler's failure mode is silent success -- it shares ~/.claude/settings.json
# with aoe and install-claude-plugins, so a merge that quietly replaces a record
# looks identical to one that preserves it until a user loses their hooks. Every
# assertion below therefore checks what SURVIVED, not only what was written.
set -euo pipefail

usage='usage: test-claude-settings-reconcile.sh SETTINGS_SCRIPT'
settings_script=${1:?$usage}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
settings_sh='.chezmoiscripts/70-agents/run_after_config-claude-settings.sh.tmpl'

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/claude-settings-reconcile-fixtures
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

# Renders resolve secrets live, so isolate them from host state: a scratch HOME
# plus a stub op answering newline-free.
render_config="$scratch/render.toml"
printf '[data]\n' >"$render_config"
neg_home="$scratch/neg-home"
neg_bin="$scratch/neg-bin"
mkdir -p "$neg_home" "$neg_bin"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' >"$neg_bin/op"
chmod 0700 "$neg_bin/op"

fail() { printf '%s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Runtime: the rendered reconciler against fixtures, driven by CLAUDE_SETTINGS.
# ---------------------------------------------------------------------------

run() { CLAUDE_SETTINGS="$1" bash "$settings_script"; }

# The declaration the rendered script carries, read back the same way the script
# does, so these assertions cannot drift from agents.yaml.
declared=$(env HOME="$neg_home" PATH="$neg_bin:$PATH" \
  chezmoi --config "$render_config" --source "$repo_root" \
  execute-template <<<'{{ .agents.claude.settings | toJson }}')

assert_declared_present() {
  local file=$1 label=$2
  jq -e --argjson d "$declared" '
    . as $live
    | [ $d | to_entries[] | . as $e | ($live | getpath($e.key | split("."))) == $e.value ]
    | all' "$file" >/dev/null \
    || fail "$label: a declared leaf is missing or holds the wrong value in $file"
}

# Claude Code reads env values as STRINGS, so an unquoted scalar in agents.yaml
# renders as a JSON number and the tool ignores the key. assert_declared_present
# cannot catch that: it compares the live value against the SAME rendered
# declaration, so an unquoted value is a number on both sides and matches. Only a
# type check over the record sees it. Declared as a record sweep rather than one
# key, so a later env leaf inherits the guard instead of needing its own line.
# The object test is not redundant: a bare `env` scalar leaf renders past the
# declaration guard, and to_entries would then abort this whole suite at the
# assignment with jq's own "has no keys" rather than the diagnostic below.
env_type_offenders() {
  jq -r '(.env // {}) | if type == "object" then (to_entries[] | select(.value | type != "string") | .key) else "env" end' "$1"
}

assert_env_types_are_strings() {
  local file=$1 label=$2 offenders
  offenders=$(env_type_offenders "$file")
  [[ -z $offenders ]] \
    || fail "$label: declared env leaves reached the settings file as non-strings: $offenders"
}

# The sweep above runs only against files the reconciler built from today's
# correctly quoted declaration, so its FAILURE branch never executed in CI -- the
# exact silent-pass the guard exists to prevent. These two fixtures force it, and
# they are written by hand so they cannot go quiet if agents.yaml changes.
mistyped_number=$scratch/env-number.json
printf '%s' '{"env":{"DISABLE_AUTOUPDATER":1,"OK_KEY":"1"}}' >"$mistyped_number"
[[ $(env_type_offenders "$mistyped_number") == 'DISABLE_AUTOUPDATER' ]] \
  || fail 'the env-type sweep did not flag a numeric env leaf by name'

mistyped_scalar=$scratch/env-scalar.json
printf '%s' '{"env":"oops"}' >"$mistyped_scalar"
[[ $(env_type_offenders "$mistyped_scalar") == 'env' ]] \
  || fail 'the env-type sweep did not flag a bare env scalar as env'

env_clean=$scratch/env-clean.json
printf '%s' '{"env":{"DISABLE_AUTOUPDATER":"1"}}' >"$env_clean"
[[ -z $(env_type_offenders "$env_clean") ]] \
  || fail 'the env-type sweep flagged a correctly typed env record'

env_absent=$scratch/env-absent.json
printf '%s' '{"language":"English"}' >"$env_absent"
[[ -z $(env_type_offenders "$env_absent") ]] \
  || fail 'the env-type sweep flagged a file that declares no env record'

# Every other writer's key, plus two values deliberately left undeclared so they
# stay adjustable through the interface.
fixture=$scratch/settings.json
cat >"$fixture" <<'JSON'
{
  "language": "English",
  "modelSettings": { "other-model": { "effortLevel": "low" } },
  "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "true" } ] } ] },
  "enabledPlugins": { "compound-engineering@compound-engineering-plugin": true },
  "extraKnownMarketplaces": { "compound-engineering-plugin": { "source": { "source": "directory" } } },
  "theme": "auto",
  "editorMode": "normal"
}
JSON
chmod 0600 "$fixture"
before_hooks=$(jq -Sc '.hooks' "$fixture")
before_plugins=$(jq -Sc '.enabledPlugins' "$fixture")
before_marketplaces=$(jq -Sc '.extraKnownMarketplaces' "$fixture")
before_other_model=$(jq -Sc '.modelSettings["other-model"]' "$fixture")

run "$fixture" >/dev/null
assert_declared_present "$fixture" 'drift run'
assert_env_types_are_strings "$fixture" 'drift run'

# Leaf ownership: the enclosing record keeps its other members, and every key the
# declaration does not name survives. This is the assertion the old top-level
# merge would have failed.
[[ $(jq -Sc '.modelSettings["other-model"]' "$fixture") == "$before_other_model" ]] \
  || fail 'sibling model entry inside modelSettings did not survive the assert'
[[ $(jq -Sc '.hooks' "$fixture") == "$before_hooks" ]] || fail 'aoe hooks did not survive the assert'
[[ $(jq -Sc '.enabledPlugins' "$fixture") == "$before_plugins" ]] || fail 'enabledPlugins did not survive the assert'
[[ $(jq -Sc '.extraKnownMarketplaces' "$fixture") == "$before_marketplaces" ]] || fail 'extraKnownMarketplaces did not survive the assert'
[[ $(jq -r '.theme' "$fixture") == auto ]] || fail 'undeclared theme was rewritten'
[[ $(jq -r '.editorMode' "$fixture") == normal ]] || fail 'undeclared editorMode was rewritten'
[[ $(stat -c '%a' "$fixture") == 600 ]] || fail 'reconciler widened the settings file mode'

# Convergence is the success case, not a skip: a second apply on unchanged source
# must change zero bytes. Inode identity is the signal that no rename happened --
# this job runs on every apply.
identity_before=$(stat -c '%i %Y' "$fixture")
converged_out=$(run "$fixture" 2>&1)
[[ $(stat -c '%i %Y' "$fixture") == "$identity_before" ]] \
  || fail 'a converged re-run republished the settings file'
[[ -z $converged_out ]] || fail "a converged re-run was not silent: $converged_out"

# A host with no settings file yet gets exactly the declared leaves.
created=$scratch/created.json
run "$created" >/dev/null
assert_declared_present "$created" 'missing target'

assert_env_types_are_strings "$created" 'missing target'

# The env record has a co-writer: Claude Code's own legacy `autoUpdates` migration
# writes into it, and .chezmoidata/agents.yaml claims convergence with that. The
# suite proves sibling preservation for modelSettings; this proves it for env,
# which is a different enclosing record and could regress on its own.
env_sibling=$scratch/env-sibling.json
printf '%s' '{"env":{"FROM_ANOTHER_WRITER":"keep-me"},"language":"English"}' >"$env_sibling"
chmod 0600 "$env_sibling"
run "$env_sibling" >/dev/null
[[ $(jq -r '.env.FROM_ANOTHER_WRITER' "$env_sibling") == 'keep-me' ]] \
  || fail 'an env key another writer owns did not survive the assert'
assert_declared_present "$env_sibling" 'env co-writer'
assert_env_types_are_strings "$env_sibling" 'env co-writer'

# A malformed live file is preserved and reported, never rebuilt: rebuilding from
# the declaration alone would drop everything the other writers own.
malformed=$scratch/malformed.json
printf 'not json{' >"$malformed"
malformed_before=$(cat "$malformed")
malformed_err=$(run "$malformed" 2>&1 >/dev/null) || fail 'malformed target should not fail the apply'
[[ $(cat "$malformed") == "$malformed_before" ]] || fail 'malformed target was overwritten'
[[ -f "$malformed.bak" ]] || fail 'malformed target was not copied aside'
grep -qF 'is not a JSON object' <<<"$malformed_err" || fail 'malformed target was not reported on stderr'

# An ancestor holding a scalar or an array cannot be written through. Both the
# probe and the write raise on it, so this proves the classifier survives to
# report rather than dying mid-stream.
#
# It must suppress ONLY its own leaf. An all-or-nothing abort left every declared
# path unwritten behind one unrelated damaged key -- including the
# DISABLE_AUTOUPDATER pin, which on macOS is that control's only carrier -- while
# the apply stayed green. So each case asserts three things: the damaged ancestor
# is untouched, its own leaf is reported by name, and every OTHER declared leaf
# landed anyway.
for bad in '{"modelSettings":"oops"}' '{"modelSettings":[1,2]}'; do
  blocked=$scratch/blocked.json
  printf '%s' "$bad" >"$blocked"
  blocked_err=$(run "$blocked" 2>&1 >/dev/null) || fail 'blocked ancestor should not fail the apply'
  [[ $(jq -Sc '.modelSettings' "$blocked") == "$(jq -Sc '.modelSettings' <<<"$bad")" ]] \
    || fail "blocked ancestor was written through: $bad"
  grep -qF 'modelSettings.claude-opus-5.effortLevel' <<<"$blocked_err" \
    || fail "blocked ancestor was not reported by path: $bad"
  jq -e --argjson d "$declared" '
    . as $live
    | [ $d | to_entries[]
        | select(.key | startswith("modelSettings.") | not)
        | . as $e | ($live | getpath($e.key | split("."))) == $e.value ]
    | all' "$blocked" >/dev/null \
    || fail "a blocked ancestor suppressed the leaves it does not own: $bad"
  rm -f "$blocked"
done

# A run whose ONLY drifted path is the blocked one must write nothing at all. The
# fixture starts from the declaration with modelSettings damaged, so every other
# leaf is already converged and there is nothing writable left to assert.
blocked_only=$scratch/blocked-only.json
jq -n --argjson d "$declared" '
  reduce ($d | to_entries[]
          | select(.key | startswith("modelSettings.") | not)) as $e
    ({}; setpath($e.key | split("."); $e.value))
  | .modelSettings = "oops"' >"$blocked_only"
chmod 0600 "$blocked_only"
blocked_only_identity=$(stat -c '%i %Y' "$blocked_only")
blocked_only_before=$(cat "$blocked_only")
run "$blocked_only" >/dev/null 2>&1 || fail 'a blocked-only run should not fail the apply'
[[ $(cat "$blocked_only") == "$blocked_only_before" ]] \
  || fail 'a run whose only drift was blocked still rewrote the settings file'
[[ $(stat -c '%i %Y' "$blocked_only") == "$blocked_only_identity" ]] \
  || fail 'a run whose only drift was blocked republished the settings file'

# The concurrent-write discard branch is the whole of R12, and it is the one branch
# a fixture cannot reach by content alone: the write must land BETWEEN this script's
# read and its rename. Shadow jq so the classification pass -- identifiable by its
# -rn flags -- rewrites the target in place on its way out, exactly as a co-writer
# using open(O_TRUNC) would. Deleting the guard from the reconciler must fail here.
race_bin=$scratch/race
mkdir -p "$race_bin"
real_jq=$(command -v jq)
cat >"$race_bin/jq" <<RACE
#!/usr/bin/env bash
"$real_jq" "\$@"; rc=\$?
if [[ ! -e "\$RACE_MARK" ]]; then
  for a in "\$@"; do
    if [[ \$a == -rn ]]; then
      : >"\$RACE_MARK"
      printf '%s' "\$RACE_CONTENT" >"\$CLAUDE_SETTINGS"
      break
    fi
  done
fi
exit \$rc
RACE
chmod 0700 "$race_bin/jq"

race_fixture=$scratch/race.json
printf '%s' '{"language":"English"}' >"$race_fixture"
race_content='{"language":"English","injectedByOtherWriter":true}'
race_err=$(RACE_MARK="$scratch/race.mark" RACE_CONTENT="$race_content" \
  PATH="$race_bin:$PATH" CLAUDE_SETTINGS="$race_fixture" bash "$settings_script" 2>&1 >/dev/null) \
  || fail 'a concurrent write should not fail the apply'
grep -qF 'changed while this apply staged its replacement' <<<"$race_err" \
  || fail "the concurrent write was not reported; stderr was: $race_err"
[[ $(cat "$race_fixture") == "$race_content" ]] \
  || fail "the staged file overwrote the concurrent writer's content"
[[ -z $(find "$(dirname "$race_fixture")" -maxdepth 1 -name '.settings.*' -print -quit) ]] \
  || fail 'the discarded staged file was left behind'

# An empty target is the residue of an interrupted in-place write. It must not halt
# assertion forever -- the absent-file path already self-heals, and there is nothing
# in a zero-byte file to preserve.
zero=$scratch/zero.json
: >"$zero"
zero_err=$(run "$zero" 2>&1 >/dev/null) || fail 'an empty target should not fail the apply'
grep -qF 'was empty' <<<"$zero_err" || fail 'an empty target was not reported on stderr'
[[ -f "$zero.bak" ]] || fail 'an empty target was not copied aside'
assert_declared_present "$zero" 'empty target'
assert_env_types_are_strings "$zero" 'empty target'

# cp follows a symlink at the DESTINATION, so a planted .bak would redirect the
# backup write into whatever it points at -- and this script runs as chezmoi_t,
# which may write trees the agent domain cannot.
canary=$scratch/canary.txt
printf 'CANARY' >"$canary"
planted=$scratch/planted.json
printf 'not json{' >"$planted"
ln -s "$canary" "$planted.bak"
planted_err=$(run "$planted" 2>&1 >/dev/null) || fail 'a planted .bak symlink should not fail the apply'
[[ $(cat "$canary") == CANARY ]] || fail 'the backup was written through a symlink into another file'
grep -qF 'is a symlink' <<<"$planted_err" || fail 'the planted .bak symlink was not reported'
rm -f "$planted.bak"

# The declaration is authoritative, so a run that cannot assert must say so. A
# silent skip leaves the user believing the values are pinned.
nojq_bin=$scratch/nojq
mkdir -p "$nojq_bin"
ln -sf "$(command -v dirname)" "$nojq_bin/dirname"
nojq_fixture=$scratch/nojq.json
printf '{"language":"English"}' >"$nojq_fixture"
nojq_before=$(cat "$nojq_fixture")
nojq_err=$(env -i HOME="$neg_home" PATH="$nojq_bin" CLAUDE_SETTINGS="$nojq_fixture" \
  "$BASH" "$settings_script" 2>&1 >/dev/null) || fail 'missing jq should not fail the apply'
[[ $(cat "$nojq_fixture") == "$nojq_before" ]] || fail 'missing jq still touched the settings file'
grep -qF 'jq is unavailable' <<<"$nojq_err" || fail 'missing jq was not reported on stderr'

# ---------------------------------------------------------------------------
# Render-time: the declaration guard. These cases are structurally invisible to
# every runtime assertion above, which receives an already-rendered script.
# ---------------------------------------------------------------------------

# `--override-data` DEEP-MERGES into the repo's real agents.yaml, so a fixture can
# only ADD a key. That is enough for every rejection, which is about a key that is
# present and wrong.
assert_render_fails() {
  local label=$1 data=$2 want=$3
  if env HOME="$neg_home" PATH="$neg_bin:$PATH" \
    chezmoi --config "$render_config" --source "$repo_root" --override-data "$data" \
    execute-template <"$repo_root/$settings_sh" >"$scratch/neg.out" 2>"$scratch/neg.err"; then
    fail "render-negative $label: expected a failed render, got exit 0"
  fi
  grep -qF -e "$want" -- "$scratch/neg.err" || {
    printf 'render-negative %s: render failed without the expected diagnostic %s\n' "$label" "$want" >&2
    sed 's/^/  /' "$scratch/neg.err" >&2
    exit 1
  }
}

# The positive cases cannot use --override-data at all: it can only add keys, so
# it can never express the EMPTY declaration the guard must accept. Render inline
# template text that builds its own settings dict and calls the partial directly.
assert_partial_ok() {
  local label=$1 body=$2
  printf '%s\n' "$body" >"$scratch/partial.tmpl"
  env HOME="$neg_home" PATH="$neg_bin:$PATH" \
    chezmoi --config "$render_config" --source "$repo_root" \
    execute-template <"$scratch/partial.tmpl" >"$scratch/pos.out" 2>"$scratch/pos.err" || {
    printf 'render-partial %s: expected a successful render, got a failure\n' "$label" >&2
    sed 's/^/  /' "$scratch/pos.err" >&2
    exit 1
  }
}

owned_elsewhere='which another writer owns'
bad_path='is not a valid settings path'

assert_render_fails hooks-namespace \
  '{"agents":{"claude":{"settings":{"hooks.SessionStart":"x"}}}}' "$owned_elsewhere"
assert_render_fails hooks-bare \
  '{"agents":{"claude":{"settings":{"hooks":"x"}}}}' "$owned_elsewhere"
assert_render_fails enabled-plugins \
  '{"agents":{"claude":{"settings":{"enabledPlugins.some-plugin":true}}}}' "$owned_elsewhere"
assert_render_fails extra-known-marketplaces \
  '{"agents":{"claude":{"settings":{"extraKnownMarketplaces":"x"}}}}' "$owned_elsewhere"
assert_render_fails doubled-dot \
  '{"agents":{"claude":{"settings":{"modelSettings..effortLevel":"high"}}}}' "$bad_path"
assert_render_fails leading-dot \
  '{"agents":{"claude":{"settings":{".language":"x"}}}}' "$bad_path"
assert_render_fails trailing-dot \
  '{"agents":{"claude":{"settings":{"language.":"x"}}}}' "$bad_path"
assert_render_fails segment-leading-digit \
  '{"agents":{"claude":{"settings":{"modelSettings.9bad":"x"}}}}' "$bad_path"

# A container value would be written wholesale and destroy the record's other
# members -- the exact clobbering the leaf-path design removes.
assert_render_fails container-value \
  '{"agents":{"claude":{"settings":{"modelSettings":{"claude-opus-5":{"effortLevel":"high"}}}}}}' \
  'must name a LEAF'
# An ancestor path plus a leaf beneath it passes every per-path check, then aborts
# the apply at runtime with a jq error naming no path.
assert_render_fails ancestor-and-descendant \
  '{"agents":{"claude":{"settings":{"modelSettings":"x"}}}}' \
  'is an ancestor of'

# An empty declaration is a legal state -- it is what this key held before adoption
# and what agents.agy.settings still holds -- so it must render a notice, not fail.
assert_partial_ok empty-declaration \
  '{{- includeTemplate "claude-settings-validate.tmpl" (dict "ctx" . "settings" dict) -}}'
# Model ids are path segments, so the grammar must admit hyphens and digits.
assert_partial_ok hyphen-and-digit-segment \
  '{{- includeTemplate "claude-settings-validate.tmpl" (dict "ctx" . "settings" (dict "modelSettings.claude-opus-5.effortLevel" "high")) -}}'
# The real declaration must always render clean.
assert_partial_ok real-declaration \
  '{{- includeTemplate "claude-settings-validate.tmpl" (dict "ctx" . "settings" .agents.claude.settings) -}}'

# The empty declaration must also render the script itself down to a notice with
# no assertion loop, rather than a body that would run against nothing.
printf '%s\n' '{{- $settings := dict -}}
{{- includeTemplate "claude-settings-validate.tmpl" (dict "ctx" . "settings" $settings) -}}
{{ if eq (len $settings) 0 }}NOTICE{{ else }}LOOP{{ end }}' >"$scratch/empty-shape.tmpl"
env HOME="$neg_home" PATH="$neg_bin:$PATH" \
  chezmoi --config "$render_config" --source "$repo_root" \
  execute-template <"$scratch/empty-shape.tmpl" | grep -qF NOTICE \
  || fail 'an empty declaration did not take the notice branch'

printf 'test-claude-settings-reconcile: all runtime and render-time assertions passed\n'
