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
printf 'build-command-reconcile fatal-boundary tests passed\n'
