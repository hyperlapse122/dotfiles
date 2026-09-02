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

# Renders resolve secrets live, so isolate them from host state exactly as the omp
# reconcile test does: a scratch HOME plus a stub op answering newline-free.
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

# Claude Code reads env values as STRINGS, so an unquoted scalar in agents.yaml
# renders as a JSON number and the tool ignores the key. assert_declared_present
# cannot catch that: it compares the live value against the SAME rendered
# declaration, so an unquoted value is a number on both sides and matches. Only a
# type check over the record sees it. Declared as a record sweep rather than one
# key, so a later env leaf inherits the guard instead of needing its own line.
# The object test is not redundant: a bare `env` scalar leaf renders past the
# declaration guard, and to_entries would then abort this whole suite at the
# assignment with jq's own "has no keys" rather than the diagnostic below.
mistyped_env=$(jq -r '(.env // {}) | if type == "object" then (to_entries[] | select(.value | type != "string") | .key) else "env" end' "$created")
[[ -z $mistyped_env ]] \
  || fail "declared env leaves reached the settings file as non-strings: $mistyped_env"

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
for bad in '{"modelSettings":"oops"}' '{"modelSettings":[1,2]}'; do
  blocked=$scratch/blocked.json
  printf '%s' "$bad" >"$blocked"
  blocked_err=$(run "$blocked" 2>&1 >/dev/null) || fail 'blocked ancestor should not fail the apply'
  [[ $(cat "$blocked") == "$bad" ]] || fail "blocked ancestor was written through: $bad"
  grep -qF 'modelSettings.claude-opus-5.effortLevel' <<<"$blocked_err" \
    || fail "blocked ancestor was not reported by path: $bad"
  rm -f "$blocked"
done

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
