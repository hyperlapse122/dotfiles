#!/usr/bin/env bash
set -euo pipefail

rendered=${1:?usage: test-build-settings-reconcile.sh RENDERED_SCRIPT}
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
scratch=$(mktemp -d "$scratch_root/settings-reconcile-build-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

prepare_case() {
  local name=$1
  case_dir="$scratch/$name"
  source_dir="$case_dir/source"
  home_dir="$case_dir/home"
  fake_bin="$case_dir/bin"
  mkdir -p "$source_dir/packages/settings-reconcile/dist" "$home_dir/.local/bin" "$fake_bin"
  cat >"$source_dir/packages/settings-reconcile/dist/settings-reconcile" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod 0755 "$source_dir/packages/settings-reconcile/dist/settings-reconcile"
  cat >"$fake_bin/mise" <<'EOF'
#!/usr/bin/env bash
case "${SETTINGS_MISE_MODE:-success}:$*" in
  dependency:*'vp install --frozen-lockfile'*) exit 41 ;;
  build:*'vp run build'*) exit 42 ;;
esac
exit 0
EOF
  chmod 0755 "$fake_bin/mise"
  sed "s|^SRC=.*$|SRC=\"$source_dir\"|" "$rendered" >"$case_dir/build.sh"
  chmod 0755 "$case_dir/build.sh"
  target="$home_dir/.local/bin/settings-reconcile"
}

assert_fatal() {
  local label=$1 diagnostic=$2
  set +e
  env HOME="$home_dir" PATH="$fake_bin:$PATH" SETTINGS_MISE_MODE="$label" bash "$case_dir/build.sh" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { printf '%s unexpectedly succeeded\n' "$label" >&2; return 1; }
  grep -F "$diagnostic" "$case_dir/stderr" >/dev/null
  if grep -E 'Recorded as done|nothing to do|installed ~/.local/bin/settings-reconcile' \
    "$case_dir/stdout" "$case_dir/stderr" >/dev/null; then
    printf '%s emitted a skip/success marker\n' "$label" >&2
    return 1
  fi
  [[ $(cat "$target") == old-executable ]] || { printf '%s replaced the older executable\n' "$label" >&2; return 1; }
  if compgen -G "$home_dir/.local/state/chezmoi/skips/*" >/dev/null; then
    printf '%s wrote a skip declaration state marker\n' "$label" >&2
    return 1
  fi
}

prepare_case dependency-install
printf old-executable >"$target"; chmod 0755 "$target"
assert_fatal dependency 'build-settings-reconcile: dependency installation failed'

prepare_case build
printf old-executable >"$target"; chmod 0755 "$target"
assert_fatal build 'build-settings-reconcile: build failed'

prepare_case missing-dist
printf old-executable >"$target"; chmod 0755 "$target"
rm -f "$source_dir/packages/settings-reconcile/dist/settings-reconcile"
assert_fatal success 'build-settings-reconcile: build completed without an executable dist artifact'

prepare_case missing-mise
printf old-executable >"$target"; chmod 0755 "$target"
rm "$fake_bin/mise"
ln -s "$(command -v mkdir)" "$fake_bin/mkdir"
env HOME="$home_dir" PATH="$fake_bin" /usr/bin/bash "$case_dir/build.sh" \
  >"$case_dir/stdout" 2>"$case_dir/stderr"
grep -F 'build-settings-reconcile: mise is not installed; settings-reconcile build is deferred' "$case_dir/stdout" >/dev/null
[[ $(cat "$target") == old-executable ]]

prepare_case unsafe-target
mkdir "$target"
env HOME="$home_dir" PATH="$fake_bin:$PATH" bash "$case_dir/build.sh" \
  >"$case_dir/stdout" 2>"$case_dir/stderr"
[[ -d "$target" ]]
grep -F 'the settings-reconcile install target is not a regular file' "$case_dir/stdout" >/dev/null

printf 'build-settings-reconcile fatal-boundary and target-safety tests passed\n'
