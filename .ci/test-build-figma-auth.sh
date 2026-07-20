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
exit 0
EOF
  chmod 0755 "$fake_bin/mise"
  sed "s|^SRC=.*$|SRC=\"$source_dir\"|" "$rendered" >"$case_dir/build.sh"
  chmod 0755 "$case_dir/build.sh"
  target="$home_dir/.local/bin/figma-auth"
}

assert_soft_skip() {
  if ! env HOME="$home_dir" PATH="$fake_bin:$PATH" bash "$case_dir/build.sh" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"; then
    printf 'expected soft skip for %s\n' "$case_dir" >&2
    return 1
  fi
  if grep -F 'build-figma-auth: installed' "$case_dir/stdout" >/dev/null; then
    printf 'unsafe target reported installation for %s\n' "$case_dir" >&2
    return 1
  fi
}

prepare_case directory
mkdir "$target"
assert_soft_skip
[[ -d "$target" ]]

prepare_case symlink
printf 'preserve-link-target\n' >"$case_dir/referent"
ln -s "$case_dir/referent" "$target"
assert_soft_skip
[[ -L "$target" ]]
[[ $(cat "$case_dir/referent") == preserve-link-target ]]

prepare_case nonregular
mkfifo "$target"
assert_soft_skip
[[ -p "$target" ]]

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
if grep -F 'build-figma-auth: installed' "$case_dir/stdout" >/dev/null; then
  printf 'TERM path reported installation success\n' >&2
  exit 1
fi

printf 'build-figma-auth fake-toolchain tests passed\n'
