#!/usr/bin/env bash
set -euo pipefail

# Proves the three harness plugin reconcilers that share
# .chezmoitemplates/agent-plugin-rows.tmpl: the rendered
# scripts carry the declared rows and the fail-closed lifecycle calls, they
# converge on a re-run instead of re-mutating, and each one rejects a marketplace
# source that cannot serve its harness. The Codex personal-marketplace templates
# under dot_agents/plugins/ are rendered here as well, because the codex script
# only works when they agree with its rows.
#
# The rendered scripts hold ABSOLUTE paths resolved against the renderer's home,
# so every fixture rewrites that path into its own scratch HOME rather than
# letting a run consult the live one.
#
# CLAUDE_SCRIPT, AGY_SCRIPT and CODEX_SCRIPT are the three reconcilers as
# rendered by `chezmoi execute-template` against this source tree. The template
# checks in the last section render dot_agents/plugins/*.tmpl themselves and
# need `chezmoi` on PATH (or CHEZMOI=/path/to/chezmoi), with the source tree
# resolved from this script's own location.

usage='usage: test-claude-agy-plugin-reconcile.sh CLAUDE_SCRIPT AGY_SCRIPT CODEX_SCRIPT'
claude_script=${1:?$usage}
agy_script=${2:?$usage}
codex_script=${3:?$usage}
source_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/claude-agy-plugin-fixtures
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
# The propagation case below writes one probe file into the source tree, because
# the version it asserts is derived from that tree. Clearing it here means an
# interrupted run cannot leave it behind.
propagation_probe=''
propagation_probe_dir=''
cleanup() {
  rm -rf -- "$scratch"
  [[ -z $propagation_probe ]] || rm -f -- "$propagation_probe"
  [[ -z $propagation_probe_dir ]] || rmdir -- "$propagation_probe_dir" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf 'test-claude-agy-plugin-reconcile: %s\n' "$*" >&2
  exit 1
}

# --- rendered surface ------------------------------------------------------ #

for needle in \
  'compound-engineering\tcompound-engineering-plugin\tlocalArchive\t' \
  'claude plugin marketplace add' \
  'claude plugin install --scope user' \
  'claude plugin update --scope user' \
  'claude plugin enable --scope user' \
  '.claude-plugin/marketplace.json'; do
  grep -F "$needle" "$claude_script" >/dev/null ||
    fail "rendered Claude Code updater is missing: $needle"
done

# `plugin update` is what re-resolves a bumped version segment: `install` alone
# is a no-op once the plugin exists at any version, so losing it would freeze the
# cache at whatever version first landed.
grep -F 'claude plugin update --scope user' "$claude_script" >/dev/null ||
  fail 'rendered Claude Code updater no longer re-resolves the pinned version'

for needle in \
  'compound-engineering\tcompound-engineering-plugin\tlocalArchive\t' \
  'agy plugin install' \
  'agy plugin enable' \
  'has no bundle root plugin.json'; do
  grep -F "$needle" "$agy_script" >/dev/null ||
    fail "rendered Antigravity updater is missing: $needle"
done

# The Codex updater installs from the chezmoi-owned personal marketplace, so the
# row it carries is the registry key the marketplace.json entry and the archive
# symlink are both named after.
for needle in \
  'compound-engineering\tcompound-engineering-plugin\tlocalArchive\t' \
  'codex plugin add' \
  'preflight: codex is not on PATH' \
  '.codex-plugin/plugin.json' \
  'PERSONAL_MARKETPLACE="dotfiles"'; do
  grep -F "$needle" "$codex_script" >/dev/null ||
    fail "rendered Codex updater is missing: $needle"
done

for script in "$claude_script" "$agy_script" "$codex_script"; do
  fingerprints=$(grep '^#   ' "$script" || true)
  [[ -n $fingerprints ]] || fail "rendered $script carries no dependency fingerprint"
  for raw_input in '.chezmoidata/agents.yaml' '.chezmoidata/releases.json'; do
    printf '%s\n' "$fingerprints" | grep -F "#   $raw_input  " >/dev/null ||
      fail "rendered $script does not fingerprint $raw_input"
  done
done

# Claude Code serves the COPY it caches per version, never the deployed source,
# so an edit reaches a session only if this script re-runs and reinstalls. That
# depends on the plugin tree being one of this script's fingerprint inputs, and
# dropping the glob would leave hook edits deployed but never served -- with
# every other assertion here still green.
claude_fingerprints=$(grep '^#   ' "$claude_script" || true)
printf '%s\n' "$claude_fingerprints" |
  grep -F '#   dot_local/share/dotfiles-claude-plugin/' >/dev/null ||
  fail 'rendered Claude updater does not fingerprint the dotfiles-claude-plugin tree'
printf '%s\n' "$claude_fingerprints" |
  grep -F '#   dot_local/share/dotfiles-claude-plugin/hooks/executable_orca-team-lead-orchestration.sh.tmpl  ' >/dev/null ||
  fail 'rendered Claude updater does not fingerprint the hook script itself'

# The payload bodies live outside the plugin tree, reached through one-line
# includeTemplate wrappers whose own source never changes. Without them as
# fingerprint inputs a reworded orchestration rule re-renders nothing, so the
# edit deploys to ~/.local/share and never reaches the cache Claude Code serves
# -- the same silent failure the tree glob above exists to prevent.
for body in orchestration-everyone.tmpl orchestration-coordinator.tmpl orchestration-role-detect.sh.tmpl; do
  printf '%s\n' "$claude_fingerprints" |
    grep -F "#   .chezmoitemplates/$body  " >/dev/null ||
    fail "rendered Claude updater does not fingerprint payload body $body"
done

# Neither script may reach a conditional `exit 0`: chezmoi records that as a
# successful run, and an empty declared set is decided at render time instead.
for script in "$claude_script" "$agy_script" "$codex_script"; do
  if grep -nE '^\s+exit 0\s*$' "$script" >/dev/null; then
    fail "rendered $script carries an indented exit 0"
  fi
done

# --- fixture marketplace --------------------------------------------------- #

home="$scratch/home"
bin="$scratch/bin"
mkdir -p "$home" "$bin"
market="$home/.local/share/compound-engineering/v-test"
mkdir -p "$market/.claude-plugin" "$market/.agy" "$market/.codex-plugin" "$market/skills/demo"

cat >"$market/.claude-plugin/marketplace.json" <<'EOF'
{"name":"compound-engineering-plugin","plugins":[{"name":"compound-engineering","source":"./"}]}
EOF
cat >"$market/.claude-plugin/plugin.json" <<'EOF'
{"name":"compound-engineering","version":"0.0.0-test"}
EOF
# Upstream ships the bundle manifest at the archive root and points its own
# compatibility entry at it. Nothing prunes it now, so the reconciler installs
# the marketplace source directly.
cat >"$market/plugin.json" <<'EOF'
{"name":"compound-engineering","version":"0.0.0-test"}
EOF
ln -s '../plugin.json' "$market/.agy/plugin.json"
cat >"$market/.codex-plugin/plugin.json" <<'EOF'
{"name":"compound-engineering","version":"0.0.0-test"}
EOF
printf -- '---\nname: demo\n---\n' >"$market/skills/demo/SKILL.md"

# The Codex fixture reproduces what chezmoi deploys under ~/.agents/plugins: the
# personal marketplace manifest and the registry-key symlink onto the archive.
mkdir -p "$home/.agents/plugins"
cat >"$home/.agents/plugins/marketplace.json" <<'EOF'
{"name":"dotfiles","plugins":[{"name":"compound-engineering","source":{"source":"local","path":"./.agents/plugins/compound-engineering-plugin"}},{"name":"dotfiles-codex","source":{"source":"local","path":"./.agents/plugins/dotfiles-codex-plugin"}}]}
EOF
ln -s "$market" "$home/.agents/plugins/compound-engineering-plugin"

# The localDir marketplace this checkout ships. Unlike the localArchive above, no
# external downloads it -- chezmoi deploys it as an ordinary target -- so the
# fixture has to stand it up itself or the reconciler's preflight has nothing to
# find. Both manifests are present because Claude Code reads the plugin manifest
# from .claude-plugin/plugin.json, not from the tree root.
local_dir_market="$home/.local/share/dotfiles-claude-plugin"
mkdir -p "$local_dir_market/.claude-plugin" "$local_dir_market/hooks"
cat >"$local_dir_market/.claude-plugin/marketplace.json" <<'EOF'
{"name":"dotfiles-claude-plugin","plugins":[{"name":"dotfiles-claude","source":"./"}]}
EOF
cat >"$local_dir_market/.claude-plugin/plugin.json" <<'EOF'
{"name":"dotfiles-claude","version":"0.1.0-test"}
EOF

# The Codex half of the same story. Its reconciler preflights three things in
# order -- the source directory, its .codex-plugin/plugin.json, and a
# ~/.agents/plugins/<registry key> symlink pointing at that directory -- and dies
# on the first miss. That die runs AFTER chezmoi has already written the
# instruction targets, so a row declared without its symlink source would leave
# the reduced instruction files on disk and abort the rest of the apply. The
# fixture stands up all three so the preflight is actually exercised rather than
# skipped.
codex_dir_market="$home/.local/share/dotfiles-codex-plugin"
mkdir -p "$codex_dir_market/.codex-plugin" "$codex_dir_market/hooks"
cat >"$codex_dir_market/.codex-plugin/plugin.json" <<'EOF'
{"name":"dotfiles-codex","version":"0.1.0-test"}
EOF
ln -s "$codex_dir_market" "$home/.agents/plugins/dotfiles-codex-plugin"

rewrite() {
  local rendered=$1 target=$2
  local row path local_row local_path
  row=$(grep -m1 'compound-engineering\\tcompound-engineering-plugin\\tlocalArchive\\t' "$rendered") ||
    fail "no compound-engineering row in $rendered"
  path=${row#*localArchive\\t}
  path=${path%%\"*}
  # Each harness carries at most one localDir row: dotfiles-claude in the Claude
  # script, dotfiles-codex in the Codex one. Each substitution is a no-op where
  # its row is absent.
  local codex_row codex_path
  local -a subs=("-e" "s|$path|$market|g")
  if local_row=$(grep -m1 'dotfiles-claude\\tdotfiles-claude-plugin\\tlocalDir\\t' "$rendered"); then
    local_path=${local_row#*localDir\\t}
    local_path=${local_path%%\"*}
    subs+=("-e" "s|$local_path|$local_dir_market|g")
  fi
  if codex_row=$(grep -m1 'dotfiles-codex\\tdotfiles-codex-plugin\\tlocalDir\\t' "$rendered"); then
    codex_path=${codex_row#*localDir\\t}
    codex_path=${codex_path%%\"*}
    subs+=("-e" "s|$codex_path|$codex_dir_market|g")
  fi
  sed "${subs[@]}" "$rendered" >"$target"
  chmod 0700 "$target"
}

claude_test="$scratch/claude-plugins.sh"
agy_test="$scratch/agy-plugins.sh"
codex_test="$scratch/codex-plugins.sh"
rewrite "$claude_script" "$claude_test"
rewrite "$agy_script" "$agy_test"
rewrite "$codex_script" "$codex_test"
grep -F "$market" "$claude_test" >/dev/null || fail 'claude fixture path rewrite did not take'
grep -F "$local_dir_market" "$claude_test" >/dev/null ||
  fail 'claude localDir fixture path rewrite did not take'
grep -F "$market" "$agy_test" >/dev/null || fail 'agy fixture path rewrite did not take'
grep -F "$market" "$codex_test" >/dev/null || fail 'codex fixture path rewrite did not take'

# --- harness stubs --------------------------------------------------------- #

# The Claude Code stub reproduces the two lifecycle facts the script is written
# against: install/marketplace-add/update are idempotent and exit 0, while
# `plugin enable` on an already-enabled plugin exits 1 with "already enabled".
cat >"$bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CLAUDE_CALLS"
case "$*" in
  "plugin marketplace add "*)
    printf '%s\n' "${*##* }" >"$HOME/.claude/plugins/declared-marketplace"
    ;;
  "plugin install --scope user "*)
    : >"$HOME/.claude/plugins/installed"
    : >"$HOME/.claude/plugins/enabled"
    ;;
  "plugin update --scope user "*)
    [[ -e $HOME/.claude/plugins/installed ]] || { printf 'not installed\n' >&2; exit 1; }
    ;;
  "plugin enable --scope user "*)
    if [[ -e $HOME/.claude/plugins/enabled ]]; then
      printf 'Failed to enable plugin: Plugin is already enabled at user scope\n' >&2
      exit 1
    fi
    : >"$HOME/.claude/plugins/enabled"
    ;;
  "plugin uninstall --scope user "*)
    rm -f "$HOME/.claude/plugins/installed" "$HOME/.claude/plugins/enabled"
    ;;
  *) printf 'unexpected claude call: %s\n' "$*" >&2; exit 64 ;;
esac
EOF
chmod 0700 "$bin/claude"

# The Antigravity stub asserts what agy itself requires of a bundle: a root
# plugin.json and a component tree it can read.
cat >"$bin/agy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$AGY_CALLS"
case "${1-} ${2-}" in
  "plugin install")
    bundle=$3
    [[ -z ${AGY_INSTALL_FAILS:-} ]] || { printf 'simulated install failure: %s\n' "$bundle" >&2; exit 1; }
    [[ -f $bundle/plugin.json ]] || { printf 'no bundle manifest: %s\n' "$bundle" >&2; exit 1; }
    [[ -f $bundle/skills/demo/SKILL.md ]] || { printf 'bundle skills unreadable: %s\n' "$bundle" >&2; exit 1; }
    ;;
  "plugin enable" | "plugin uninstall") ;;
  *) printf 'unexpected agy call: %s\n' "$*" >&2; exit 64 ;;
esac
EOF
chmod 0700 "$bin/agy"

# The Codex stub reproduces the two lifecycle facts the script is written against,
# both verified against codex-cli 0.153.4: `plugin add` on an already-installed
# plugin re-asserts the install and exits 0, and every install rewrites
# ~/.codex/config.toml. The install record lives under CODEX_STATE so a run never
# touches the marketplace tree, which Codex must not write to.
cat >"$bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CODEX_CALLS"
mkdir -p "$CODEX_STATE"
case "${1-} ${2-}" in
  "plugin add")
    id=$3
    [[ -z ${CODEX_ADD_FAILS:-} ]] || { printf 'simulated add failure: %s\n' "$id" >&2; exit 1; }
    : >"$CODEX_STATE/${id%@*}"
    mkdir -p "$HOME/.codex"
    : >>"$HOME/.codex/config.toml"
    ;;
  "plugin remove")
    rm -f "$CODEX_STATE/${3%@*}"
    ;;
  *) printf 'unexpected codex call: %s\n' "$*" >&2; exit 64 ;;
esac
EOF
chmod 0700 "$bin/codex"

claude_calls="$scratch/claude-calls"
agy_calls="$scratch/agy-calls"
codex_calls="$scratch/codex-calls"
: >"$claude_calls"
: >"$agy_calls"
: >"$codex_calls"

run_claude() { env HOME="$home" PATH="$bin:$PATH" CLAUDE_CALLS="$claude_calls" bash "${1:-$claude_test}"; }
run_agy() { env HOME="$home" PATH="$bin:$PATH" AGY_CALLS="$agy_calls" bash "$agy_test"; }
run_codex() {
  env HOME="$home" PATH="$bin:$PATH" CODEX_CALLS="$codex_calls" CODEX_STATE="$scratch/codex-state" \
    bash "$codex_test"
}

# --- Claude Code: first apply, then a converged re-run --------------------- #

run_claude >"$scratch/claude.out" 2>&1 || {
  cat "$scratch/claude.out" >&2
  fail 'first Claude Code reconcile failed'
}
grep -Fx "plugin marketplace add $market" "$claude_calls" >/dev/null ||
  fail 'Claude Code reconcile did not register the declared marketplace'
grep -Fx 'plugin install --scope user compound-engineering@compound-engineering-plugin' "$claude_calls" >/dev/null ||
  fail 'Claude Code reconcile did not install the declared plugin'
grep -Fx 'plugin update --scope user compound-engineering@compound-engineering-plugin' "$claude_calls" >/dev/null ||
  fail 'Claude Code reconcile did not re-resolve the declared plugin'

# The re-run hits `plugin enable` on an already-enabled plugin, which the real CLI
# reports as a failure. Tolerating exactly that message is what keeps a converged
# apply green without swallowing a genuine enable failure.
run_claude >"$scratch/claude-2.out" 2>&1 || {
  cat "$scratch/claude-2.out" >&2
  fail 'converged Claude Code re-run failed on the already-enabled plugin'
}
# Counted per plugin rather than in total: the declaration now carries more than
# one Claude Code plugin, and a total would drift every time another is added.
for declared in compound-engineering@compound-engineering-plugin \
  dotfiles-claude@dotfiles-claude-plugin; do
  [[ $(grep -c "plugin enable --scope user $declared" "$claude_calls") -eq 2 ]] ||
    fail "Claude Code reconcile did not re-assert the enabled state for $declared"
done

# --- Claude Code: the localDir marketplace --------------------------------- #

# This is the first localDir consumer in the repository, so the branch in
# agent-plugin-rows.tmpl that resolves `path` against $HOME had no coverage until
# here. The reconciler does not branch on kind, so the same add/install/update
# sequence must reach it.
grep -Fx "plugin marketplace add $local_dir_market" "$claude_calls" >/dev/null ||
  fail 'Claude Code reconcile did not register the localDir marketplace'
grep -Fx 'plugin install --scope user dotfiles-claude@dotfiles-claude-plugin' "$claude_calls" >/dev/null ||
  fail 'Claude Code reconcile did not install the localDir plugin'
grep -Fx 'plugin update --scope user dotfiles-claude@dotfiles-claude-plugin' "$claude_calls" >/dev/null ||
  fail 'Claude Code reconcile did not update the localDir plugin'

# Claude Code reads a plugin's manifest from .claude-plugin/plugin.json and
# serves the COPY it caches, so the manifest sitting on the wrong surface in the
# source tree would install a marketplace with no usable plugin.
[[ -f "$source_root/dot_local/share/dotfiles-claude-plugin/dot_claude-plugin/plugin.json.tmpl" ]] ||
  fail 'the shipped plugin tree carries no .claude-plugin/plugin.json manifest'

local_dir_missing="$scratch/no-local-dir"
sed "s|$local_dir_market|$local_dir_missing|g" "$claude_test" >"$scratch/claude-nolocaldir.sh"
chmod 0700 "$scratch/claude-nolocaldir.sh"
if run_claude "$scratch/claude-nolocaldir.sh" >"$scratch/claude-nolocaldir.out" 2>&1; then
  fail 'Claude Code reconcile accepted a localDir marketplace whose directory is absent'
fi
grep -F 'dotfiles-claude-plugin' "$scratch/claude-nolocaldir.out" >/dev/null ||
  fail 'the absent localDir marketplace was rejected without naming it'

local_dir_bare="$scratch/local-dir-no-manifest"
mkdir -p "$local_dir_bare"
sed "s|$local_dir_market|$local_dir_bare|g" "$claude_test" >"$scratch/claude-localdir-bare.sh"
chmod 0700 "$scratch/claude-localdir-bare.sh"
if run_claude "$scratch/claude-localdir-bare.sh" >"$scratch/claude-localdir-bare.out" 2>&1; then
  fail 'Claude Code reconcile accepted a localDir marketplace with no Claude Code manifest'
fi
grep -F '.claude-plugin/marketplace.json' "$scratch/claude-localdir-bare.out" >/dev/null ||
  fail 'the manifest-less localDir marketplace was rejected without naming the manifest path'

# A tree with the marketplace manifest but no plugin manifest used to install
# happily at an unknown version. The version is the cache key, so that state
# serves one copy forever and every later edit is deployed but never served.
local_dir_no_plugin="$scratch/local-dir-no-plugin"
mkdir -p "$local_dir_no_plugin/.claude-plugin"
cp "$local_dir_market/.claude-plugin/marketplace.json" "$local_dir_no_plugin/.claude-plugin/"
sed "s|$local_dir_market|$local_dir_no_plugin|g" "$claude_test" >"$scratch/claude-localdir-noplugin.sh"
chmod 0700 "$scratch/claude-localdir-noplugin.sh"
if run_claude "$scratch/claude-localdir-noplugin.sh" >"$scratch/claude-localdir-noplugin.out" 2>&1; then
  fail 'Claude Code reconcile installed a localDir marketplace with no plugin manifest'
fi
grep -F '.claude-plugin/plugin.json' "$scratch/claude-localdir-noplugin.out" >/dev/null ||
  fail 'the plugin-manifest-less marketplace was rejected without naming the plugin manifest'

# --- Claude Code: a source that cannot serve this harness ------------------ #

no_manifest="$scratch/no-claude-manifest"
mkdir -p "$no_manifest"
sed "s|$market|$no_manifest|g" "$claude_test" >"$scratch/claude-bad.sh"
chmod 0700 "$scratch/claude-bad.sh"
if env HOME="$home" PATH="$bin:$PATH" CLAUDE_CALLS="$claude_calls" \
  bash "$scratch/claude-bad.sh" >"$scratch/claude-bad.out" 2>&1; then
  fail 'Claude Code reconcile accepted a marketplace with no Claude Code manifest'
fi
grep -F 'no Claude Code manifest' "$scratch/claude-bad.out" >/dev/null ||
  fail 'Claude Code reconcile rejected the bad marketplace without naming the cause'

# --- Antigravity: direct install, then a converged re-run ------------------ #

run_agy >"$scratch/agy.out" 2>&1 || {
  cat "$scratch/agy.out" >&2
  fail 'first Antigravity reconcile failed'
}
grep -Fx "plugin install $market" "$agy_calls" >/dev/null ||
  fail 'Antigravity reconcile did not install the marketplace source directly'
grep -Fx 'plugin enable compound-engineering' "$agy_calls" >/dev/null ||
  fail 'Antigravity reconcile did not enable the declared plugin'
[[ ! -e $home/.local/share/agy-plugin-bundles ]] ||
  fail 'Antigravity reconcile staged a bundle the source already provides'

: >"$agy_calls"
run_agy >"$scratch/agy-2.out" 2>&1 || {
  cat "$scratch/agy-2.out" >&2
  fail 'converged Antigravity re-run failed'
}
grep -Fx "plugin uninstall compound-engineering" "$agy_calls" >/dev/null &&
  fail 'converged Antigravity re-run re-mutated an already-installed plugin'

# --- Antigravity: a host still serving the superseded staged bundle -------- #

stale="$home/.local/share/agy-plugin-bundles/compound-engineering-plugin/compound-engineering"
mkdir -p "$stale"
cp "$market/plugin.json" "$stale/plugin.json"
ln -s "$market/skills" "$stale/skills"
: >"$agy_calls"
run_agy >"$scratch/agy-3.out" 2>&1 || {
  cat "$scratch/agy-3.out" >&2
  fail 'Antigravity migration off the staged bundle failed'
}
grep -Fx 'plugin uninstall compound-engineering' "$agy_calls" >/dev/null ||
  fail 'Antigravity reconcile did not release the superseded staged bundle'
grep -Fx "plugin install $market" "$agy_calls" >/dev/null ||
  fail 'Antigravity reconcile did not re-point the plugin at the marketplace source'
[[ ! -e $stale ]] || fail 'Antigravity reconcile left the superseded staged bundle behind'

: >"$agy_calls"
run_agy >"$scratch/agy-4.out" 2>&1 || {
  cat "$scratch/agy-4.out" >&2
  fail 'Antigravity re-run after migration failed'
}
grep -Fx 'plugin uninstall compound-engineering' "$agy_calls" >/dev/null &&
  fail 'Antigravity migration re-ran after the staged bundle was gone'

# --- Antigravity: a failed install must not consume the migration signal --- #

mkdir -p "$stale"
cp "$market/plugin.json" "$stale/plugin.json"
ln -s "$market/skills" "$stale/skills"
: >"$agy_calls"
if AGY_INSTALL_FAILS=1 run_agy >"$scratch/agy-7.out" 2>&1; then
  fail 'Antigravity reconcile reported success on a failing install'
fi
[[ -d $stale ]] ||
  fail 'a failed install removed the staged bundle, so the next apply cannot retry the migration'

: >"$agy_calls"
run_agy >"$scratch/agy-8.out" 2>&1 || {
  cat "$scratch/agy-8.out" >&2
  fail 'the retry after a failed install did not converge'
}
grep -Fx "plugin install $market" "$agy_calls" >/dev/null ||
  fail 'the retry did not re-point the plugin at the marketplace source'
[[ ! -e $stale ]] || fail 'the successful retry left the staged bundle behind'

# --- Antigravity: a source whose root manifest is absent or misdeclared ---- #

mv "$market/plugin.json" "$scratch/plugin.json.bak"
if run_agy >"$scratch/agy-5.out" 2>&1; then
  fail 'Antigravity reconcile installed a source with no bundle root manifest'
fi
grep -F 'has no bundle root plugin.json' "$scratch/agy-5.out" >/dev/null ||
  fail 'Antigravity reconcile rejected the manifest-less source without naming the cause'

cat >"$market/plugin.json" <<'EOF'
{"name":"someone-elses-plugin","version":"0.0.0-test"}
EOF
if run_agy >"$scratch/agy-6.out" 2>&1; then
  fail 'Antigravity reconcile installed a bundle declaring a different plugin'
fi
grep -F 'does not declare plugin compound-engineering' "$scratch/agy-6.out" >/dev/null ||
  fail 'Antigravity reconcile rejected the misdeclared bundle without naming the cause'
mv "$scratch/plugin.json.bak" "$market/plugin.json"

# --- Codex: relabel, install, then a converged re-run ---------------------- #

run_codex >"$scratch/codex.out" 2>&1 || {
  cat "$scratch/codex.out" >&2
  fail 'first Codex reconcile failed'
}
grep -Fx 'plugin add compound-engineering@dotfiles' "$codex_calls" >/dev/null ||
  fail 'Codex reconcile did not install the plugin from the personal marketplace'

# The re-run hits `plugin add` on an already-installed plugin, which Codex treats
# as a successful re-assert, so a converged apply stays green while a genuine
# install failure below still fails the run.
: >"$codex_calls"
run_codex >"$scratch/codex-2.out" 2>&1 || {
  cat "$scratch/codex-2.out" >&2
  fail 'converged Codex re-run failed on the already-installed plugin'
}
grep -Fx 'plugin add compound-engineering@dotfiles' "$codex_calls" >/dev/null ||
  fail 'converged Codex re-run did not re-assert the installed state'

if CODEX_ADD_FAILS=1 run_codex >"$scratch/codex-3.out" 2>&1; then
  fail 'Codex reconcile reported success on a failing plugin add'
fi
grep -F 'plugin add failed for compound-engineering@dotfiles' "$scratch/codex-3.out" >/dev/null ||
  fail 'Codex reconcile swallowed a genuine plugin add failure'

# --- Codex: preflight failures --------------------------------------------- #

no_codex="$scratch/bin-no-codex"
mkdir -p "$no_codex"
if env HOME="$home" PATH="$no_codex:/usr/bin:/bin" CODEX_CALLS="$codex_calls" \
  CODEX_STATE="$scratch/codex-state" bash "$codex_test" >"$scratch/codex-4.out" 2>&1; then
  fail 'Codex reconcile ran without a codex binary'
fi
grep -F 'preflight: codex is not on PATH' "$scratch/codex-4.out" >/dev/null ||
  fail 'Codex reconcile did not name the missing codex binary'

mv "$market/.codex-plugin/plugin.json" "$scratch/codex-plugin.json.bak"
if run_codex >"$scratch/codex-5.out" 2>&1; then
  fail 'Codex reconcile installed a source with no Codex plugin manifest'
fi
grep -F 'no Codex plugin manifest' "$scratch/codex-5.out" >/dev/null ||
  fail 'Codex reconcile rejected the manifest-less source without naming the cause'
mv "$scratch/codex-plugin.json.bak" "$market/.codex-plugin/plugin.json"

rm "$home/.agents/plugins/compound-engineering-plugin"
ln -s "$scratch/elsewhere" "$home/.agents/plugins/compound-engineering-plugin"
if run_codex >"$scratch/codex-6.out" 2>&1; then
  fail 'Codex reconcile accepted a marketplace symlink pointing away from the archive'
fi
grep -F 'does not point at' "$scratch/codex-6.out" >/dev/null ||
  fail 'Codex reconcile rejected the stale marketplace symlink without naming the cause'
rm "$home/.agents/plugins/compound-engineering-plugin"
ln -s "$market" "$home/.agents/plugins/compound-engineering-plugin"

# --- Codex: the personal marketplace templates ----------------------------- #

# These render against the real source tree, so the checks are about the SHAPE
# Codex requires (a `./`-relative path per plugin, the registry key as the
# symlink name) and about agreement with agent-plugin-rows.tmpl, never about a
# particular version segment.
chezmoi_bin=$(command -v "${CHEZMOI:-chezmoi}") ||
  fail 'chezmoi is required to render dot_agents/plugins templates (set CHEZMOI=/path/to/chezmoi)'
render_bin="$scratch/render-bin"
mkdir -p "$render_bin" "$scratch/render-target"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' \
  >"$render_bin/op"
chmod 0700 "$render_bin/op"
: >"$scratch/empty.toml"
render() {
  env PATH="$render_bin:$PATH" "$chezmoi_bin" --config "$scratch/empty.toml" --source "$source_root" \
    --destination "$scratch/render-target" execute-template "$@"
}

# --- propagation: the plugin version must move with the plugin tree ---------- #
#
# `plugin install` is a no-op once the plugin exists at ANY version, so the
# version rendered here IS the cache key. A version that does not move when the
# tree does leaves every later edit deployed to ~/.local/share and never served.
# The tree is a standing home for hooks, agents and commands, so this asserts
# against a file outside hooks/ -- the shape that a hooks-only digest would miss.
plugin_manifest_tmpl="$source_root/dot_local/share/dotfiles-claude-plugin/dot_claude-plugin/plugin.json.tmpl"
[[ -f $plugin_manifest_tmpl ]] || fail "missing $plugin_manifest_tmpl"

render_plugin_version() {
  render <"$plugin_manifest_tmpl" 2>"$scratch/plugin-manifest.err" |
    jq -er '.version' 2>/dev/null
}

version_before=$(render_plugin_version) || {
  cat "$scratch/plugin-manifest.err" >&2
  fail 'plugin.json.tmpl failed to render'
}
[[ -n $version_before ]] || fail 'plugin.json.tmpl rendered no version'

version_repeat=$(render_plugin_version) || fail 'plugin.json.tmpl failed to re-render'
[[ $version_repeat == "$version_before" ]] ||
  fail "plugin version is unstable across renders of unchanged source: $version_before then $version_repeat"

probe_dir="$source_root/dot_local/share/dotfiles-claude-plugin/commands"
[[ -d $probe_dir ]] || propagation_probe_dir="$probe_dir"
mkdir -p "$probe_dir"
propagation_probe="$probe_dir/.ce-propagation-probe"
printf 'propagation probe\n' >"$propagation_probe"
version_after=$(render_plugin_version) || version_after=''
rm -f -- "$propagation_probe"
propagation_probe=''
[[ -z $propagation_probe_dir ]] || { rmdir -- "$propagation_probe_dir" 2>/dev/null; propagation_probe_dir=''; }
[[ -n $version_after ]] || fail 'plugin.json.tmpl failed to render with an extra tree file'
[[ $version_after != "$version_before" ]] ||
  fail 'adding a file outside hooks/ left the plugin version unchanged, so that file would never reach the cache'

version_restored=$(render_plugin_version) || fail 'plugin.json.tmpl failed to render after the probe was removed'
[[ $version_restored == "$version_before" ]] ||
  fail "removing the probe did not restore the plugin version: $version_before then $version_restored"

marketplace_tmpl="$source_root/dot_agents/plugins/readonly_marketplace.json.tmpl"
symlink_tmpl="$source_root/dot_agents/plugins/symlink_compound-engineering-plugin.tmpl"
[[ -f $marketplace_tmpl ]] || fail "missing $marketplace_tmpl"
[[ -f $symlink_tmpl ]] || fail "missing $symlink_tmpl"

render <"$marketplace_tmpl" >"$scratch/marketplace.json" 2>"$scratch/marketplace.err" || {
  cat "$scratch/marketplace.err" >&2
  fail 'marketplace.json template failed to render'
}
jq -e . "$scratch/marketplace.json" >/dev/null || fail 'rendered marketplace.json is not valid JSON'
[[ $(jq -r '.name' "$scratch/marketplace.json") == dotfiles ]] ||
  fail 'rendered marketplace.json does not name the dotfiles personal marketplace'
# Codex resolves a `./`-relative plugin path against $HOME, not against this
# manifest's own directory, so the path has to spell out ~/.agents/plugins. An
# absolute path is not an alternative: Codex drops such an entry and then reports
# the plugin as missing from the marketplace.
[[ $(jq -r '.plugins[] | select(.name == "compound-engineering") | .source.path' "$scratch/marketplace.json") == \
  './.agents/plugins/compound-engineering-plugin' ]] ||
  fail 'rendered marketplace.json does not map compound-engineering onto ./.agents/plugins/compound-engineering-plugin'
[[ $(jq -r '.plugins[] | select(.name == "compound-engineering") | .source.source' "$scratch/marketplace.json") == local ]] ||
  fail 'rendered marketplace.json plugin source is not local'
[[ $(jq -r '[.plugins[].source.path | select(startswith("./.agents/plugins/") | not)] | length' "$scratch/marketplace.json") -eq 0 ]] ||
  fail 'rendered marketplace.json carries a plugin path that is not relative to $HOME/.agents/plugins'
! grep -F "$HOME" "$scratch/marketplace.json" >/dev/null ||
  fail 'rendered marketplace.json leaks the absolute home path'

# The symlink target is the fourth field of the codex plugin row, computed by
# agent-plugin-rows.tmpl and nowhere else.
printf '%s' '{{ includeTemplate "agent-plugin-rows.tmpl" (dict "ctx" . "harness" "codex" "field" "plugins") }}' |
  render >"$scratch/codex-rows" || fail 'agent-plugin-rows.tmpl failed to render for codex'
row_path=$(grep -m1 'compound-engineering\\tcompound-engineering-plugin\\tlocalArchive\\t' "$scratch/codex-rows") ||
  fail 'agent-plugin-rows.tmpl yields no codex compound-engineering row'
row_path=${row_path#*localArchive\\t}
row_path=${row_path%%\"*}
[[ $row_path == /* ]] || fail "codex row path is not absolute: $row_path"
render <"$symlink_tmpl" >"$scratch/symlink-target" 2>"$scratch/symlink.err" || {
  cat "$scratch/symlink.err" >&2
  fail 'archive symlink template failed to render'
}
symlink_target=$(tr -d '\n' <"$scratch/symlink-target")
[[ $symlink_target == "$row_path" ]] ||
  fail "archive symlink target $symlink_target differs from the row path $row_path"

# A symlink source named after a key the registry does not declare must fail at
# render time. The key is the template's one constant, so renaming it in a copy
# is the same edit as renaming the source file.
sed 's/compound-engineering-plugin/not-a-declared-marketplace/g' "$symlink_tmpl" >"$scratch/symlink-unknown.tmpl"
if render <"$scratch/symlink-unknown.tmpl" >/dev/null 2>"$scratch/symlink-unknown.err"; then
  fail 'archive symlink template rendered for a marketplace the registry does not declare'
fi
grep -F 'not-a-declared-marketplace' "$scratch/symlink-unknown.err" >/dev/null ||
  fail 'archive symlink template failed without naming the unknown marketplace'

# A registry entry of another kind has no archive path to link.
if render --override-data '{"agents":{"marketplaces":{"compound-engineering-plugin":{"kind":"localDir","path":"x"}}}}' \
  <"$symlink_tmpl" >/dev/null 2>"$scratch/symlink-kind.err"; then
  fail 'archive symlink template rendered for a marketplace that is not a localArchive'
fi
grep -F 'localArchive' "$scratch/symlink-kind.err" >/dev/null ||
  fail 'archive symlink template failed on the wrong kind without naming it'

# An empty declared set renders an empty marketplace, a notice, and no loop; the
# symlink then has no row to follow and fails closed.
empty='{"agents":{"codex":{"plugins":[]}}}'
render --override-data "$empty" <"$marketplace_tmpl" >"$scratch/marketplace-empty.json" ||
  fail 'marketplace.json template failed to render with no declared plugins'
[[ $(jq -r '.plugins | length' "$scratch/marketplace-empty.json") -eq 0 ]] ||
  fail 'marketplace.json still lists a plugin with none declared'
render --override-data "$empty" <"$source_root/.chezmoiscripts/70-agents/run_onchange_after_update-codex-plugins.sh.tmpl" \
  >"$scratch/codex-empty.sh" || fail 'codex updater failed to render with no declared plugins'
grep -F 'no eligible plugins or removals are declared' "$scratch/codex-empty.sh" >/dev/null ||
  fail 'codex updater with no declared plugins carries no notice'
! grep -F 'for row in' "$scratch/codex-empty.sh" >/dev/null ||
  fail 'codex updater with no declared plugins still renders a loop'
if render --override-data "$empty" <"$symlink_tmpl" >/dev/null 2>"$scratch/symlink-empty.err"; then
  fail 'archive symlink template rendered with no codex row referencing its key'
fi

# A declared removal renders a best-effort `plugin remove` loop that runs before
# the installs, and the label restore still follows the last Codex write.
removal='{"agents":{"codex":{"pluginsRemoved":[{"name":"retired","marketplace":"compound-engineering-plugin"}]}}}'
render --override-data "$removal" <"$source_root/.chezmoiscripts/70-agents/run_onchange_after_update-codex-plugins.sh.tmpl" \
  >"$scratch/codex-removal.rendered" || fail 'codex updater failed to render with a declared removal'
rewrite "$scratch/codex-removal.rendered" "$scratch/codex-removal.sh"
: >"$codex_calls"
env HOME="$home" PATH="$bin:$PATH" CODEX_CALLS="$codex_calls" CODEX_STATE="$scratch/codex-state" \
  bash "$scratch/codex-removal.sh" >"$scratch/codex-removal.out" 2>&1 || {
  cat "$scratch/codex-removal.out" >&2
  fail 'Codex reconcile with a declared removal failed'
}
grep -Fx 'plugin remove retired@dotfiles' "$codex_calls" >/dev/null ||
  fail 'Codex reconcile did not remove the declared plugin'
[[ $(grep -n 'plugin remove' "$codex_calls" | head -1 | cut -d: -f1) -lt \
  $(grep -n 'plugin add' "$codex_calls" | head -1 | cut -d: -f1) ]] ||
  fail 'Codex reconcile installed before removing the declared plugin'
printf 'test-claude-agy-plugin-reconcile: ok\n'
