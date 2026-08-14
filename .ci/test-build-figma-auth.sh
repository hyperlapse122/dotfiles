#!/usr/bin/env bash
set -euo pipefail

rendered=${1:?usage: test-build-figma-auth.sh RENDERED_SCRIPT}
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
scratch=$(mktemp -d "$scratch_root/figma-auth-build-test.XXXXXX")
cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT

prepare_case() {
  local name=$1
  case_dir="$scratch/$name"
  source_dir="$case_dir/source"
  home_dir="$case_dir/home"
  fake_bin="$case_dir/bin"
  mkdir -p "$source_dir/packages/figma-auth/dist" "$home_dir/.local/bin" "$fake_bin"
  cat >"$source_dir/packages/figma-auth/dist/figma-auth" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod 0755 "$source_dir/packages/figma-auth/dist/figma-auth"
  cat >"$fake_bin/mise" <<'EOF'
#!/usr/bin/env bash
case "${FIGMA_MISE_MODE:-success}:$*" in
  dependency:*'vp install --frozen-lockfile'*) exit 41 ;;
  build:*'vp run build'*) exit 42 ;;
esac
exit 0
EOF
  chmod 0755 "$fake_bin/mise"
  sed "s|^SRC=.*$|SRC=\"$source_dir\"|" "$rendered" >"$case_dir/build.sh"
  chmod 0755 "$case_dir/build.sh"
  target="$home_dir/.local/bin/figma-auth"
}

assert_no_success_marker() {
  local output=$1
  if grep -E 'Recorded as done|nothing to do|installed ~/.local/bin/figma-auth' "$output" >/dev/null; then
    printf 'fatal path emitted a skip/success marker: %s\n' "$output" >&2
    return 1
  fi
}

assert_fatal() {
  local label=$1 diagnostic=$2
  set +e
  env HOME="$home_dir" PATH="$fake_bin:$PATH" FIGMA_MISE_MODE="$label" bash "$case_dir/build.sh" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { printf '%s unexpectedly succeeded\n' "$label" >&2; return 1; }
  grep -F "$diagnostic" "$case_dir/stderr" >/dev/null
  assert_no_success_marker "$case_dir/stdout"
  assert_no_success_marker "$case_dir/stderr"
  [[ $(cat "$target") == old-executable ]] || {
    printf '%s replaced the older executable\n' "$label" >&2
    return 1
  }
  if compgen -G "$home_dir/.local/state/chezmoi/skips/*" >/dev/null; then
    printf '%s wrote a skip declaration state marker\n' "$label" >&2
    return 1
  fi
}

# Fatal boundary: all three failures must be nonzero despite a good older target.
prepare_case dependency-install
printf old-executable >"$target"; chmod 0755 "$target"
assert_fatal dependency 'build-figma-auth: dependency installation failed'

prepare_case build
printf old-executable >"$target"; chmod 0755 "$target"
assert_fatal build 'build-figma-auth: build failed'

prepare_case missing-dist
printf old-executable >"$target"; chmod 0755 "$target"
rm -f "$source_dir/packages/figma-auth/dist/figma-auth"
assert_fatal success 'build-figma-auth: build completed without an executable dist artifact'

# Missing mise remains a classified, non-fatal transient-blocking outcome.
prepare_case missing-mise
printf old-executable >"$target"; chmod 0755 "$target"
rm "$fake_bin/mise"
ln -s "$(command -v mkdir)" "$fake_bin/mkdir"
env HOME="$home_dir" PATH="$fake_bin" /usr/bin/bash "$case_dir/build.sh" \
  >"$case_dir/stdout" 2>"$case_dir/stderr"
grep -F 'build-figma-auth: mise is not installed; figma-auth build is deferred' "$case_dir/stdout" >/dev/null
[[ $(cat "$target") == old-executable ]]

# Unsafe targets remain a classified harmless outcome and must not be promoted.
prepare_case directory
mkdir "$target"
env HOME="$home_dir" PATH="$fake_bin:/usr/bin:/bin" bash "$case_dir/build.sh" \
  >"$case_dir/stdout" 2>"$case_dir/stderr"
[[ -d "$target" ]]
grep -F 'the figma-auth install target is not a regular file' "$case_dir/stdout" >/dev/null

prepare_case symlink
printf 'preserve-link-target\n' >"$case_dir/referent"
ln -s "$case_dir/referent" "$target"
env HOME="$home_dir" PATH="$fake_bin:/usr/bin:/bin" bash "$case_dir/build.sh" \
  >"$case_dir/stdout" 2>"$case_dir/stderr"
[[ -L "$target" ]]
[[ $(cat "$case_dir/referent") == preserve-link-target ]]

prepare_case term
printf 'original-executable\n' >"$target"
chmod 0755 "$target"
cat >"$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
kill -TERM "$PPID"
exit 0
EOF
chmod 0755 "$fake_bin/mv"
set +e
env HOME="$home_dir" PATH="$fake_bin:$PATH" bash "$case_dir/build.sh" \
  >"$case_dir/stdout" 2>"$case_dir/stderr"
status=$?
set -e
[[ $status -eq 143 ]]
[[ $(cat "$target") == original-executable ]]
if compgen -G "$home_dir/.local/bin/.figma-auth.*" >/dev/null; then
  printf 'TERM left a promotion temporary file behind\n' >&2
  exit 1
fi
assert_no_success_marker "$case_dir/stdout"

printf 'build-figma-auth fatal-boundary and target-safety tests passed\n'
