#!/usr/bin/env bash
set -euo pipefail

# Proves the two harness plugin reconcilers that share
# .chezmoitemplates/agent-plugin-rows.tmpl: the rendered
# scripts carry the declared rows and the fail-closed lifecycle calls, they
# converge on a re-run instead of re-mutating, and each one rejects a marketplace
# source that cannot serve its harness.
#
# The rendered scripts hold ABSOLUTE paths resolved against the renderer's home,
# so every fixture rewrites that path into its own scratch HOME rather than
# letting a run consult the live one.

usage='usage: test-claude-agy-plugin-reconcile.sh CLAUDE_SCRIPT AGY_SCRIPT'
claude_script=${1:?$usage}
agy_script=${2:?$usage}

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/claude-agy-plugin-fixtures
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() {
  rm -rf -- "$scratch"
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

for script in "$claude_script" "$agy_script"; do
  fingerprints=$(grep '^#   ' "$script" || true)
  [[ -n $fingerprints ]] || fail "rendered $script carries no dependency fingerprint"
  for raw_input in '.chezmoidata/agents.yaml' '.chezmoidata/releases.json'; do
    printf '%s\n' "$fingerprints" | grep -F "#   $raw_input  " >/dev/null ||
      fail "rendered $script does not fingerprint $raw_input"
  done
done

# Neither script may reach a conditional `exit 0`: chezmoi records that as a
# successful run, and an empty declared set is decided at render time instead.
for script in "$claude_script" "$agy_script"; do
  if grep -nE '^\s+exit 0\s*$' "$script" >/dev/null; then
    fail "rendered $script carries an indented exit 0"
  fi
done

# --- fixture marketplace --------------------------------------------------- #

home="$scratch/home"
bin="$scratch/bin"
mkdir -p "$home" "$bin"
market="$home/.local/share/compound-engineering/v-test"
mkdir -p "$market/.claude-plugin" "$market/.agy" "$market/skills/demo"

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
printf -- '---\nname: demo\n---\n' >"$market/skills/demo/SKILL.md"

rewrite() {
  local rendered=$1 target=$2
  local row path
  row=$(grep -m1 'compound-engineering\\tcompound-engineering-plugin\\tlocalArchive\\t' "$rendered") ||
    fail "no compound-engineering row in $rendered"
  path=${row#*localArchive\\t}
  path=${path%%\"*}
  sed "s|$path|$market|g" "$rendered" >"$target"
  chmod 0700 "$target"
}

claude_test="$scratch/claude-plugins.sh"
agy_test="$scratch/agy-plugins.sh"
rewrite "$claude_script" "$claude_test"
rewrite "$agy_script" "$agy_test"
grep -F "$market" "$claude_test" >/dev/null || fail 'claude fixture path rewrite did not take'
grep -F "$market" "$agy_test" >/dev/null || fail 'agy fixture path rewrite did not take'

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
    [[ -f $bundle/plugin.json ]] || { printf 'no bundle manifest: %s\n' "$bundle" >&2; exit 1; }
    [[ -f $bundle/skills/demo/SKILL.md ]] || { printf 'bundle skills unreadable: %s\n' "$bundle" >&2; exit 1; }
    ;;
  "plugin enable" | "plugin uninstall") ;;
  *) printf 'unexpected agy call: %s\n' "$*" >&2; exit 64 ;;
esac
EOF
chmod 0700 "$bin/agy"

claude_calls="$scratch/claude-calls"
agy_calls="$scratch/agy-calls"
: >"$claude_calls"
: >"$agy_calls"

run_claude() { env HOME="$home" PATH="$bin:$PATH" CLAUDE_CALLS="$claude_calls" bash "$claude_test"; }
run_agy() { env HOME="$home" PATH="$bin:$PATH" AGY_CALLS="$agy_calls" bash "$agy_test"; }

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
[[ $(grep -c 'plugin enable --scope user' "$claude_calls") -eq 2 ]] ||
  fail 'Claude Code reconcile did not re-assert the enabled state'

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

printf 'test-claude-agy-plugin-reconcile: ok\n'
