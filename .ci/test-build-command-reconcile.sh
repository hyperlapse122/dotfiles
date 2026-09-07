#!/usr/bin/env bash
set -euo pipefail

rendered=${1:?usage: test-build-command-reconcile.sh RENDERED_SCRIPT}
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
scratch=$(mktemp -d "$scratch_root/command-reconcile-build-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

prepare_case() {
  local name=$1
  case_dir="$scratch/$name"
  source_dir="$case_dir/source"
  home_dir="$case_dir/home"
  fake_bin="$case_dir/bin"
  mkdir -p "$source_dir/packages/command-reconcile/dist" "$home_dir/.local/libexec" "$fake_bin"
  cat >"$source_dir/packages/command-reconcile/dist/command-reconcile" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod 0755 "$source_dir/packages/command-reconcile/dist/command-reconcile"
  cat >"$fake_bin/mise" <<'EOF'
#!/usr/bin/env bash
case "${COMMAND_RECONCILE_MISE_MODE:-success}:$*" in
  dependency:*'vp install --frozen-lockfile'*) exit 41 ;;
  build:*'vp run build'*) exit 42 ;;
esac
exit 0
EOF
  chmod 0755 "$fake_bin/mise"
  sed "s|^SRC=.*$|SRC=\"$source_dir\"|" "$rendered" >"$case_dir/build.sh"
  chmod 0755 "$case_dir/build.sh"
  target="$home_dir/.local/libexec/command-reconcile"
}

assert_fatal() {
  local label=$1 diagnostic=$2
  set +e
  env HOME="$home_dir" PATH="$fake_bin:$PATH" COMMAND_RECONCILE_MISE_MODE="$label" bash "$case_dir/build.sh" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { printf '%s unexpectedly succeeded\n' "$label" >&2; return 1; }
  grep -F "$diagnostic" "$case_dir/stderr" >/dev/null
  if grep -E 'Recorded as done|nothing to do|installed ~/.local/libexec/command-reconcile' \
    "$case_dir/stdout" "$case_dir/stderr" >/dev/null; then
    printf '%s emitted a skip/success marker\n' "$label" >&2
    return 1
  fi
  [[ $(cat "$target") == old-executable ]] || { printf '%s replaced the older executable\n' "$label" >&2; return 1; }
}

# The bun cases run under PATH="$fake_bin" alone, so a bun on the runner's own
# PATH cannot satisfy the resolution ladder for us and every rung the fixture
# reaches is a rung the ladder actually walked. That leaves the build script
# without the few externals it calls after the build, so link them in.
sandbox_tools() {
  local tool
  for tool in env bash mkdir mktemp chmod cp mv rm; do
    ln -sf "$(command -v "$tool")" "$fake_bin/$tool"
  done
}

# A bun stand-in that records the path it was executed from and the PATH it
# inherited. The first answers which rung won; the second answers whether
# BUN_DIR was prepended once or twice.
write_fake_bun() {
  local path=$1 marker=$2
  mkdir -p "${path%/*}"
  cat >"$path" <<EOF
#!/usr/bin/env bash
printf '%s' "\$0" >"$marker"
printf '%s' "\$PATH" >"$marker.path"
exit 0
EOF
  chmod 0755 "$path"
}

assert_bun_build() {
  local label=$1 expected_bun=$2
  set +e
  env HOME="$home_dir" PATH="$fake_bin" /usr/bin/bash "$case_dir/build.sh" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  status=$?
  set -e
  [[ $status -eq 0 ]] || {
    printf '%s exited %s\n' "$label" "$status" >&2
    cat "$case_dir/stderr" >&2
    return 1
  }
  grep -F 'build-command-reconcile: installed ~/.local/libexec/command-reconcile' \
    "$case_dir/stdout" >/dev/null
  [[ -f "$case_dir/bun-invoked" ]] || { printf '%s never invoked bun\n' "$label" >&2; return 1; }
  [[ $(cat "$case_dir/bun-invoked") == "$expected_bun" ]] || {
    printf '%s resolved bun as %s, expected %s\n' "$label" "$(cat "$case_dir/bun-invoked")" "$expected_bun" >&2
    return 1
  }
  [[ $(cat "$target") != old-executable ]] || { printf '%s left the older executable in place\n' "$label" >&2; return 1; }
}

prepare_case dependency-install
printf old-executable >"$target"; chmod 0755 "$target"
assert_fatal dependency 'build-command-reconcile: dependency installation failed'

prepare_case build
printf old-executable >"$target"; chmod 0755 "$target"
assert_fatal build 'build-command-reconcile: build failed'

prepare_case missing-dist
printf old-executable >"$target"; chmod 0755 "$target"
rm -f "$source_dir/packages/command-reconcile/dist/command-reconcile"
assert_fatal success 'build-command-reconcile: build completed without an executable dist artifact'

prepare_case missing-toolchain
printf old-executable >"$target"; chmod 0755 "$target"
rm "$fake_bin/mise"
ln -s "$(command -v mkdir)" "$fake_bin/mkdir"
set +e
env HOME="$home_dir" PATH="$fake_bin" /usr/bin/bash "$case_dir/build.sh" \
  >"$case_dir/stdout" 2>"$case_dir/stderr"
status=$?
set -e
[[ $status -ne 0 ]]
grep -F 'build-command-reconcile: neither mise nor bun is installed' "$case_dir/stderr" >/dev/null
[[ $(cat "$target") == old-executable ]]

# mise present, bun absent everywhere. Reachable since bun left mise's tool set:
# the mise branch would run `vp run build`, whose task shells out to `bun build`,
# and fail three levels down with a build error that never names bun.
prepare_case missing-bun
printf old-executable >"$target"; chmod 0755 "$target"
sandbox_tools
set +e
env HOME="$home_dir" PATH="$fake_bin" /usr/bin/bash "$case_dir/build.sh" \
  >"$case_dir/stdout" 2>"$case_dir/stderr"
status=$?
set -e
[[ $status -ne 0 ]]
grep -F 'build-command-reconcile: bun is not installed' "$case_dir/stderr" >/dev/null
[[ $(cat "$target") == old-executable ]]

# Ladder rung 4. On a fresh host's first apply the public ~/.local/bin/bun link
# does not exist yet — it is created by run_after_90-activate-command-links,
# which needs the binary this very script builds — so the staging directory an
# external just wrote is the only bun there is.
prepare_case bun-staging
printf old-executable >"$target"; chmod 0755 "$target"
rm "$fake_bin/mise"
sandbox_tools
write_fake_bun "$home_dir/.local/share/chezmoi-commands/incomplete/bun/bun" "$case_dir/bun-invoked"
assert_bun_build bun-staging "$home_dir/.local/share/chezmoi-commands/incomplete/bun/bun"

# Ladder rung 3. A host whose public link is gone but whose command store still
# holds a current generation.
prepare_case bun-current-generation
printf old-executable >"$target"; chmod 0755 "$target"
rm "$fake_bin/mise"
sandbox_tools
write_fake_bun "$home_dir/.local/lib/commands/current/bun/bun" "$case_dir/bun-invoked"
assert_bun_build bun-current-generation "$home_dir/.local/lib/commands/current/bun/bun"

# A bun the script can already see beats staging. The script prepends
# $HOME/.local/bin to PATH before the ladder runs, so this pair is decided at
# rung 1, not rung 2 — which is exactly the state a provisioned host is in.
prepare_case bun-public-link-beats-staging
printf old-executable >"$target"; chmod 0755 "$target"
rm "$fake_bin/mise"
sandbox_tools
write_fake_bun "$home_dir/.local/bin/bun" "$case_dir/bun-invoked"
write_fake_bun "$home_dir/.local/share/chezmoi-commands/incomplete/bun/bun" "$case_dir/bun-invoked"
assert_bun_build bun-public-link-beats-staging "$home_dir/.local/bin/bun"

# Neither of these two rungs is reachable from PATH, so only the ladder's own
# ordering can decide between them. Reorder the candidate list and this fails.
prepare_case bun-current-beats-staging
printf old-executable >"$target"; chmod 0755 "$target"
rm "$fake_bin/mise"
sandbox_tools
write_fake_bun "$home_dir/.local/lib/commands/current/bun/bun" "$case_dir/bun-invoked"
write_fake_bun "$home_dir/.local/share/chezmoi-commands/incomplete/bun/bun" "$case_dir/bun-invoked"
assert_bun_build bun-current-beats-staging "$home_dir/.local/lib/commands/current/bun/bun"

# The mise path spawns `bun build --compile` as a grandchild that resolves `bun`
# from PATH, not from BUN_BIN. This mise stand-in reproduces that shape, so the
# case fails unless the ladder prepended BUN_DIR to PATH.
prepare_case bun-subprocess-path
printf old-executable >"$target"; chmod 0755 "$target"
sandbox_tools
cat >"$fake_bin/mise" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'vp run build'*) exec bun build --compile ;;
esac
exit 0
EOF
chmod 0755 "$fake_bin/mise"
write_fake_bun "$home_dir/.local/share/chezmoi-commands/incomplete/bun/bun" "$case_dir/bun-invoked"
assert_bun_build bun-subprocess-path "$home_dir/.local/share/chezmoi-commands/incomplete/bun/bun"

# Rung 1. A bun already on PATH must not have its directory prepended a second
# time; the ladder reuses the repo's `case ":$PATH:"` guard for that.
prepare_case bun-path-no-duplicate
printf old-executable >"$target"; chmod 0755 "$target"
rm "$fake_bin/mise"
sandbox_tools
write_fake_bun "$fake_bin/bun" "$case_dir/bun-invoked"
assert_bun_build bun-path-no-duplicate "$fake_bin/bun"
occurrences=$(awk -v RS=':' -v dir="$fake_bin" '$0 == dir { n++ } END { print n + 0 }' "$case_dir/bun-invoked.path")
[[ $occurrences -eq 1 ]] || {
  printf 'bun-path-no-duplicate saw %s on PATH %s time(s)\n' "$fake_bin" "$occurrences" >&2
  exit 1
}

printf 'build-command-reconcile fatal-boundary and bun-ladder tests passed\n'
