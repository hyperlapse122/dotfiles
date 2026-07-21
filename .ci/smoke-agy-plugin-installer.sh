#!/usr/bin/env bash
set -euo pipefail

rendered=${1:?usage: smoke-agy-plugin-installer.sh RENDERED_SCRIPT SCRATCH_DIR}
scratch=${2:?usage: smoke-agy-plugin-installer.sh RENDERED_SCRIPT SCRATCH_DIR}
runtime_bin="$scratch/bin"
calls="$scratch/calls.log"
fixture="$scratch/compound-engineering"
runtime_script="$scratch/installer.sh"
mkdir -p "$runtime_bin" "$fixture/skills" "$scratch/home-success" "$scratch/home-failure"
printf '%s\n' '{"name":"compound-engineering"}' > "$fixture/plugin.json"

agy_path=$(grep -E '^[[:space:]]*"agy:compound-engineering:' "$rendered" | sed -E 's/.*:localArchive:(.*)"/\1/')
cp "$rendered" "$runtime_script"
OLD="$agy_path" NEW="$fixture" perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$runtime_script"

cat > "$runtime_bin/agy" <<'EOF'
#!/usr/bin/env bash
printf 'agy %s\n' "$*" >> "${AGY_SMOKE_CALLS:?}"
[[ "${AGY_SMOKE_FAIL-}" != "${2-}" ]]
EOF
cat > "$runtime_bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >> "${AGY_SMOKE_CALLS:?}"
EOF
cat > "$runtime_bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex %s\n' "$*" >> "${AGY_SMOKE_CALLS:?}"
EOF
cat > "$runtime_bin/jq" <<'EOF'
#!/usr/bin/env bash
sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${@: -1}"
EOF
chmod 0700 "$runtime_bin/agy" "$runtime_bin/claude" "$runtime_bin/codex" "$runtime_bin/jq"

: > "$calls"
env HOME="$scratch/home-success" AGY_SMOKE_CALLS="$calls" \
  PATH="$runtime_bin:$PATH" bash "$runtime_script"
install_line=$(grep -n '^agy plugin install ' "$calls" | cut -d: -f1)
validate_line=$(grep -n '^agy plugin validate ' "$calls" | cut -d: -f1)
test -n "$install_line" && test -n "$validate_line"
test "$install_line" -lt "$validate_line"

: > "$calls"
env HOME="$scratch/home-failure" AGY_SMOKE_CALLS="$calls" AGY_SMOKE_FAIL=install \
  PATH="$runtime_bin:$PATH" bash "$runtime_script" 2> "$scratch/failure.stderr"
grep -F 'agy: skipped compound-engineering (install failed' "$scratch/failure.stderr"
test "$(grep -c '^agy plugin install ' "$calls")" -eq 1
test "$(grep -c '^agy plugin validate ' "$calls")" -eq 0
grep -q '^claude ' "$calls"

mismatch_script="$scratch/mismatched-installer.sh"
mkdir -p "$scratch/home-mismatch"
cp "$runtime_script" "$mismatch_script"
printf '%s\n' '{"name":"wrong-plugin"}' > "$fixture/plugin.json"
: > "$calls"
env HOME="$scratch/home-mismatch" AGY_SMOKE_CALLS="$calls" \
  PATH="$runtime_bin:$PATH" bash "$mismatch_script" 2> "$scratch/mismatch.stderr"
grep -F 'agy: skipped compound-engineering (manifest declares wrong-plugin' "$scratch/mismatch.stderr"
test "$(grep -c '^agy ' "$calls")" -eq 0
