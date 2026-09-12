#!/usr/bin/env bash
# Guards the agent trust reconciler (agent-trust-reconcile) and orca-ide wrapper:
# 1. Automatic checkout discovery in ~/src and ~/.local/share/worktrees
# 2. Additive trust assertions in ~/.claude.json, ~/.codex/config.toml, and
#    ~/.gemini/antigravity-cli/settings.json
# 3. Preservation of unrelated keys, existing projects, and existing trust entries
# 4. Idempotency across runs
# 5. Explicit path handling
# 6. orca-ide wrapper interception of worktree create
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
reconcile_bin="$repo_root/dot_local/share/chezmoi-command-sources/executable_agent-trust-reconcile"
orca_wrapper="$repo_root/dot_local/share/chezmoi-command-sources/executable_orca-ide"

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/agent-trust-fixtures
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

fail() { printf 'test-agent-trust-reconcile: %s\n' "$*" >&2; exit 1; }
pass() { printf 'test-agent-trust-reconcile: ok - %s\n' "$*"; }

[[ -x "$reconcile_bin" ]] || fail "reconcile_bin not found or not executable: $reconcile_bin"
[[ -x "$orca_wrapper" ]] || fail "orca_wrapper not found or not executable: $orca_wrapper"

resolve_reconciler() {
  if [[ -n ${RECONCILER:-} ]]; then
    printf '%s' "$RECONCILER"
  elif [[ -x "$HOME/.local/bin/settings-reconcile" ]]; then
    printf '%s' "$HOME/.local/bin/settings-reconcile"
  else
    # shellcheck source=.ci/lib/bun.sh
    source "$repo_root/.ci/lib/bun.sh"
    resolve_bun
    if [[ -n "$BUN_BIN" && -f "$repo_root/packages/settings-reconcile/src/cli.ts" ]]; then
      local bun_launcher="$scratch/settings-reconcile-bun"
      cat >"$bun_launcher" <<EOF
#!/usr/bin/env bash
exec "$BUN_BIN" run "$repo_root/packages/settings-reconcile/src/cli.ts" "\$@"
EOF
      chmod 0700 "$bun_launcher"
      printf '%s' "$bun_launcher"
    fi
  fi
}

rec_cmd=$(resolve_reconciler || true)

test_home="$scratch/home"
src_dir="$scratch/src"
worktrees_dir="$scratch/worktrees"
mkdir -p "$test_home" "$src_dir" "$worktrees_dir"

claude_json="$test_home/.claude.json"
agy_settings="$test_home/.gemini/antigravity-cli/settings.json"
codex_home="$test_home/.codex"
codex_config="$codex_home/config.toml"

# Create mock repositories
repo1="$src_dir/github.com/org/repo1"
mkdir -p "$repo1/.git"
repo2="$src_dir/git.example.com/team/repo2"
mkdir -p "$repo2/.git"
wt1="$worktrees_dir/dotfiles/skimmer"
mkdir -p "$wt1"
printf 'gitdir: /some/path\n' > "$wt1/.git"

# ---------------------------------------------------------------------------
# Test 1: Fresh state reconciliation
# ---------------------------------------------------------------------------
env \
  HOME="$test_home" \
  SRC_DIR="$src_dir" \
  WORKTREES_DIR="$worktrees_dir" \
  CLAUDE_CONFIG_FILE="$claude_json" \
  ANTIGRAVITY_SETTINGS_FILE="$agy_settings" \
  CODEX_HOME="$codex_home" \
  CODEX_CONFIG_FILE="$codex_config" \
  RECONCILER="$rec_cmd" \
  "$reconcile_bin"

[[ -f "$claude_json" ]] || fail "claude_json was not created"
[[ -f "$agy_settings" ]] || fail "agy_settings was not created"
[[ -f "$codex_config" ]] || fail "codex_config was not created"

# Verify permissions (0600)
mode_claude=$(stat -c '%a' "$claude_json" 2>/dev/null || stat -f '%Lp' "$claude_json")
[[ "$mode_claude" == "600" ]] || fail "claude_json mode is $mode_claude, expected 600"
mode_agy=$(stat -c '%a' "$agy_settings" 2>/dev/null || stat -f '%Lp' "$agy_settings")
[[ "$mode_agy" == "600" ]] || fail "agy_settings mode is $mode_agy, expected 600"
mode_codex=$(stat -c '%a' "$codex_config" 2>/dev/null || stat -f '%Lp' "$codex_config")
[[ "$mode_codex" == "600" ]] || fail "codex_config mode is $mode_codex, expected 600"

# Verify claude trust
repo1_resolved=$(cd "$repo1" && pwd -P)
wt1_resolved=$(cd "$wt1" && pwd -P)

jq -e --arg p "$repo1_resolved" '.projects[$p].hasTrustDialogAccepted == true' "$claude_json" >/dev/null \
  || fail "claude_json missing trust for repo1"
jq -e --arg p "$wt1_resolved" '.projects[$p].hasTrustDialogAccepted == true' "$claude_json" >/dev/null \
  || fail "claude_json missing trust for wt1"

# Verify antigravity trust
jq -e --arg p "$repo1_resolved" '.trustedWorkspaces | index($p) != null' "$agy_settings" >/dev/null \
  || fail "agy_settings missing trust for repo1"
jq -e --arg p "$wt1_resolved" '.trustedWorkspaces | index($p) != null' "$agy_settings" >/dev/null \
  || fail "agy_settings missing trust for wt1"

# Verify codex trust
grep -F "[projects.\"$repo1_resolved\"]" "$codex_config" >/dev/null \
  || fail "codex_config missing section for repo1"
grep -F "[projects.\"$wt1_resolved\"]" "$codex_config" >/dev/null \
  || fail "codex_config missing section for wt1"

pass "fresh state reconciliation creates trust entries with 0600 mode"

# ---------------------------------------------------------------------------
# Test 2: Idempotency (subsequent run produces byte-identical files)
# ---------------------------------------------------------------------------
claude_snapshot=$(cat "$claude_json")
agy_snapshot=$(cat "$agy_settings")
codex_snapshot=$(cat "$codex_config")

env \
  HOME="$test_home" \
  SRC_DIR="$src_dir" \
  WORKTREES_DIR="$worktrees_dir" \
  CLAUDE_CONFIG_FILE="$claude_json" \
  ANTIGRAVITY_SETTINGS_FILE="$agy_settings" \
  CODEX_HOME="$codex_home" \
  CODEX_CONFIG_FILE="$codex_config" \
  RECONCILER="$rec_cmd" \
  "$reconcile_bin"

[[ "$(cat "$claude_json")" == "$claude_snapshot" ]] || fail "claude_json changed on idempotent rerun"
[[ "$(cat "$agy_settings")" == "$agy_snapshot" ]] || fail "agy_settings changed on idempotent rerun"
[[ "$(cat "$codex_config")" == "$codex_snapshot" ]] || fail "codex_config changed on idempotent rerun"

pass "reconciliation is idempotent"

# ---------------------------------------------------------------------------
# Test 3: Preservation of existing unrelated data
# ---------------------------------------------------------------------------
# Add unrelated keys
tmp_claude=$(mktemp "$scratch/claude.XXXXXX")
jq '.numStartups = 42 | .projects["/other/proj"] = {"allowedTools":["bash"]}' "$claude_json" > "$tmp_claude"
mv "$tmp_claude" "$claude_json"

tmp_agy=$(mktemp "$scratch/agy.XXXXXX")
jq '.telemetryEnabled = false | .trustedWorkspaces += ["/prior/trusted"]' "$agy_settings" > "$tmp_agy"
mv "$tmp_agy" "$agy_settings"

printf '\n[features]\nmemories = false\n\n[projects."/prior/codex"]\ntrust_level = "trusted"\n' >> "$codex_config"

# Add a 3rd mock repo
repo3="$src_dir/github.com/org/repo3"
mkdir -p "$repo3/.git"
repo3_resolved=$(cd "$repo3" && pwd -P)

env \
  HOME="$test_home" \
  SRC_DIR="$src_dir" \
  WORKTREES_DIR="$worktrees_dir" \
  CLAUDE_CONFIG_FILE="$claude_json" \
  ANTIGRAVITY_SETTINGS_FILE="$agy_settings" \
  CODEX_HOME="$codex_home" \
  CODEX_CONFIG_FILE="$codex_config" \
  RECONCILER="$rec_cmd" \
  "$reconcile_bin"

# Assert preserved keys in claude
jq -e '.numStartups == 42' "$claude_json" >/dev/null || fail "claude numStartups was clobbered"
jq -e '.projects["/other/proj"].allowedTools == ["bash"]' "$claude_json" >/dev/null || fail "claude /other/proj was clobbered"
jq -e --arg p "$repo3_resolved" '.projects[$p].hasTrustDialogAccepted == true' "$claude_json" >/dev/null || fail "claude missing repo3"

# Assert preserved keys in agy
jq -e '.telemetryEnabled == false' "$agy_settings" >/dev/null || fail "agy telemetryEnabled was clobbered"
jq -e '.trustedWorkspaces | index("/prior/trusted") != null' "$agy_settings" >/dev/null || fail "agy /prior/trusted was dropped"
jq -e --arg p "$repo3_resolved" '.trustedWorkspaces | index($p) != null' "$agy_settings" >/dev/null || fail "agy missing repo3"

# Assert preserved keys in codex
grep -F 'memories = false' "$codex_config" >/dev/null || fail "codex memories feature was clobbered"
grep -F '[projects."/prior/codex"]' "$codex_config" >/dev/null || fail "codex /prior/codex was dropped"
grep -F "[projects.\"$repo3_resolved\"]" "$codex_config" >/dev/null || fail "codex missing repo3"

pass "unrelated settings and prior trust entries survive intact"

# ---------------------------------------------------------------------------
# Test 4: Explicit path arguments
# ---------------------------------------------------------------------------
explicit_target="$scratch/explicit-checkout"
mkdir -p "$explicit_target/.git"
explicit_resolved=$(cd "$explicit_target" && pwd -P)

env \
  HOME="$test_home" \
  CLAUDE_CONFIG_FILE="$claude_json" \
  ANTIGRAVITY_SETTINGS_FILE="$agy_settings" \
  CODEX_HOME="$codex_home" \
  CODEX_CONFIG_FILE="$codex_config" \
  RECONCILER="$rec_cmd" \
  "$reconcile_bin" "$explicit_target"

jq -e --arg p "$explicit_resolved" '.projects[$p].hasTrustDialogAccepted == true' "$claude_json" >/dev/null \
  || fail "claude_json missing explicit path trust"
jq -e --arg p "$explicit_resolved" '.trustedWorkspaces | index($p) != null' "$agy_settings" >/dev/null \
  || fail "agy_settings missing explicit path trust"
grep -F "[projects.\"$explicit_resolved\"]" "$codex_config" >/dev/null \
  || fail "codex_config missing explicit path trust"

pass "explicit path argument reconciliation works"

# ---------------------------------------------------------------------------
# Test 5: orca-ide wrapper interception
# ---------------------------------------------------------------------------
mock_orca_real="$scratch/mock-orca-real"
mock_orca_log="$scratch/mock-orca.log"
cat >"$mock_orca_real" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$@" >> "${MOCK_ORCA_LOG}"
if [[ "$*" == *"worktree create --name human-wt"* ]]; then
  cat <<OUT
id: wt-123
displayName: human-wt
path: ${TEST_WT_HUMAN}
head: dummyhead
OUT
elif [[ "$*" == *"worktree create --name json-wt"* ]]; then
  cat <<OUT
{
  "result": {
    "worktree": {
      "id": "wt-456",
      "path": "${TEST_WT_JSON}"
    }
  }
}
OUT
else
  echo "orca pass-through: ok"
fi
EOF
chmod 0700 "$mock_orca_real"

test_wt_human="$worktrees_dir/dotfiles/human-wt"
mkdir -p "$test_wt_human/.git"
test_wt_json="$worktrees_dir/dotfiles/json-wt"
mkdir -p "$test_wt_json/.git"

test_wt_human_resolved=$(cd "$test_wt_human" && pwd -P)
test_wt_json_resolved=$(cd "$test_wt_json" && pwd -P)

# 5a: Pass-through command
out_pass=$(env \
  ORCA_REAL_BIN="$mock_orca_real" \
  MOCK_ORCA_LOG="$mock_orca_log" \
  "$orca_wrapper" status)
[[ "$out_pass" == *"orca pass-through: ok"* ]] || fail "orca wrapper pass-through failed"

# 5b: worktree create (human output)
out_human=$(env \
  ORCA_REAL_BIN="$mock_orca_real" \
  MOCK_ORCA_LOG="$mock_orca_log" \
  TEST_WT_HUMAN="$test_wt_human_resolved" \
  TEST_WT_JSON="$test_wt_json_resolved" \
  AGENT_TRUST_RECONCILER="$reconcile_bin" \
  CLAUDE_CONFIG_FILE="$claude_json" \
  ANTIGRAVITY_SETTINGS_FILE="$agy_settings" \
  CODEX_HOME="$codex_home" \
  CODEX_CONFIG_FILE="$codex_config" \
  RECONCILER="$rec_cmd" \
  "$orca_wrapper" worktree create --name human-wt)

[[ "$out_human" == *"path: $test_wt_human_resolved"* ]] || fail "orca wrapper did not output human result"
jq -e --arg p "$test_wt_human_resolved" '.projects[$p].hasTrustDialogAccepted == true' "$claude_json" >/dev/null \
  || fail "orca wrapper failed to seed claude trust for human-wt"
grep -F "[projects.\"$test_wt_human_resolved\"]" "$codex_config" >/dev/null \
  || fail "orca wrapper failed to seed codex trust for human-wt"

# 5c: worktree create (json output)
out_json=$(env \
  ORCA_REAL_BIN="$mock_orca_real" \
  MOCK_ORCA_LOG="$mock_orca_log" \
  TEST_WT_HUMAN="$test_wt_human_resolved" \
  TEST_WT_JSON="$test_wt_json_resolved" \
  AGENT_TRUST_RECONCILER="$reconcile_bin" \
  CLAUDE_CONFIG_FILE="$claude_json" \
  ANTIGRAVITY_SETTINGS_FILE="$agy_settings" \
  CODEX_HOME="$codex_home" \
  CODEX_CONFIG_FILE="$codex_config" \
  RECONCILER="$rec_cmd" \
  "$orca_wrapper" --json worktree create --name json-wt)

[[ "$out_json" == *"$test_wt_json_resolved"* ]] || fail "orca wrapper did not output json result"
jq -e --arg p "$test_wt_json_resolved" '.projects[$p].hasTrustDialogAccepted == true' "$claude_json" >/dev/null \
  || fail "orca wrapper failed to seed claude trust for json-wt"
grep -F "[projects.\"$test_wt_json_resolved\"]" "$codex_config" >/dev/null \
  || fail "orca wrapper failed to seed codex trust for json-wt"

pass "orca-ide wrapper passes through non-create commands and seeds trust on worktree create"

printf 'test-agent-trust-reconcile: all assertions passed\n'
