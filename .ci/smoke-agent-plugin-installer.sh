#!/usr/bin/env bash
set -euo pipefail

rendered=${1:?usage: smoke-agent-plugin-installer.sh RENDERED_SCRIPT SCRATCH_DIR}
scratch=${2:?usage: smoke-agent-plugin-installer.sh RENDERED_SCRIPT SCRATCH_DIR}
runtime_bin="$scratch/bin"
calls="$scratch/calls.log"
archive_fixture="$scratch/compound-engineering"
claude_haptic_fixture="$scratch/mxm4-haptic-claude"
codex_haptic_fixture="$scratch/mxm4-haptic-codex"
runtime_script="$scratch/installer.sh"
mkdir -p "$runtime_bin" \
  "$archive_fixture/.claude-plugin" \
  "$claude_haptic_fixture/.claude-plugin" \
  "$codex_haptic_fixture/.claude-plugin" \
  "$scratch/home-success" "$scratch/home-failure" "$scratch/home-missing"
printf '%s\n' '{"name":"compound-engineering-plugin"}' \
  > "$archive_fixture/.claude-plugin/marketplace.json"
printf '%s\n' '{"name":"dotfiles"}' \
  > "$claude_haptic_fixture/.claude-plugin/marketplace.json"
printf '%s\n' '{"name":"dotfiles-codex"}' \
  > "$codex_haptic_fixture/.claude-plugin/marketplace.json"

archive_path=$(sed -n 's/^[[:space:]]*"claude:compound-engineering:compound-engineering-plugin:localArchive:\(.*\)"/\1/p' "$rendered")
claude_haptic_path=$(sed -n 's/^[[:space:]]*"claude:mxm4-haptic:dotfiles:localDir:\(.*\)"/\1/p' "$rendered")
codex_haptic_path=$(sed -n 's/^[[:space:]]*"codex:mxm4-haptic:dotfiles-codex:localDir:\(.*\)"/\1/p' "$rendered")
test -n "$archive_path"
if [[ -n "$claude_haptic_path" || -n "$codex_haptic_path" ]]; then
  test -n "$claude_haptic_path"
  test -n "$codex_haptic_path"
fi

cp "$rendered" "$runtime_script"
OLD="$archive_path" NEW="$archive_fixture" perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$runtime_script"
if [[ -n "$claude_haptic_path" ]]; then
  OLD="$claude_haptic_path" NEW="$claude_haptic_fixture" \
    perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$runtime_script"
  OLD="$codex_haptic_path" NEW="$codex_haptic_fixture" \
    perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$runtime_script"
fi

cat > "$runtime_bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >> "${PLUGIN_SMOKE_CALLS:?}"
if [[ "${CLAUDE_SMOKE_FAIL-}" == add && "${3-}" == add ]]; then
  exit 1
fi
EOF
cat > "$runtime_bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex %s\n' "$*" >> "${PLUGIN_SMOKE_CALLS:?}"
EOF
chmod 0700 "$runtime_bin/claude" "$runtime_bin/codex"

: > "$calls"
env HOME="$scratch/home-success" PLUGIN_SMOKE_CALLS="$calls" \
  PATH="$runtime_bin:$PATH" bash "$runtime_script"
grep -F 'claude plugin marketplace remove compound-engineering-plugin --scope user' "$calls"
grep -F "claude plugin marketplace add $archive_fixture --scope user" "$calls"
grep -F 'claude plugin install compound-engineering@compound-engineering-plugin --scope user' "$calls"
grep -F 'codex plugin marketplace remove compound-engineering-plugin' "$calls"
grep -F "codex plugin marketplace add $archive_fixture" "$calls"
grep -F 'codex plugin add compound-engineering@compound-engineering-plugin' "$calls"
if [[ -n "$claude_haptic_path" ]]; then
  grep -F "claude plugin marketplace add $claude_haptic_fixture --scope user" "$calls"
  grep -F 'claude plugin install mxm4-haptic@dotfiles --scope user' "$calls"
  grep -F "codex plugin marketplace add $codex_haptic_fixture" "$calls"
  grep -F 'codex plugin add mxm4-haptic@dotfiles-codex' "$calls"
  if grep -Fq 'claude plugin marketplace remove dotfiles' "$calls"; then
    exit 1
  fi
  if grep -Fq 'codex plugin marketplace remove dotfiles-codex' "$calls"; then
    exit 1
  fi
else
  if grep -q 'mxm4-haptic' "$calls"; then
    exit 1
  fi
fi
if grep -q '^agy ' "$calls"; then
  exit 1
fi

: > "$calls"
env HOME="$scratch/home-failure" PLUGIN_SMOKE_CALLS="$calls" CLAUDE_SMOKE_FAIL=add \
  PATH="$runtime_bin:$PATH" bash "$runtime_script" 2> "$scratch/failure.stderr"
grep -F 'claude: skipped compound-engineering (marketplace add failed' "$scratch/failure.stderr"
if grep -q '^claude plugin install ' "$calls"; then
  exit 1
fi
grep -F 'codex plugin add compound-engineering@compound-engineering-plugin' "$calls"

rm -f "$archive_fixture/.claude-plugin/marketplace.json"
: > "$calls"
env HOME="$scratch/home-missing" PLUGIN_SMOKE_CALLS="$calls" \
  PATH="$runtime_bin:$PATH" bash "$runtime_script" 2> "$scratch/missing.stderr"
grep -F 'no marketplace at' "$scratch/missing.stderr"
if grep -q 'compound-engineering' "$calls"; then
  exit 1
fi
