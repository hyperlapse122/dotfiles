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
  mkdir -p "$source_dir/packages/settings-reconcile/dist" \
    "$source_dir/packages/settings-reconcile/src" \
    "$home_dir/.local/share/chezmoi-commands/incomplete/settings-reconcile" "$fake_bin"
  printf 'export {};\n' >"$source_dir/packages/settings-reconcile/src/cli.ts"
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
  target="$home_dir/.local/share/chezmoi-commands/incomplete/settings-reconcile/settings-reconcile"
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
  if grep -E 'Recorded as done|nothing to do|staged settings-reconcile' \
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

# The bun cases run under PATH="$fake_bin" alone, so a bun or mise on the
# runner's own PATH cannot satisfy the script for us. That leaves the script
# without the few externals it calls around the build, so link them in.
sandbox_tools() {
  local tool
  for tool in env bash mkdir mktemp chmod cp mv rm; do
    ln -sf "$(command -v "$tool")" "$fake_bin/$tool"
  done
}

# A bun stand-in that models the ONE fact this script's bun path turns on:
# settings-reconcile imports smol-toml, so `bun build --compile` cannot resolve
# its entry point until `bun install` has populated packages/node_modules. A
# bun branch that skips the install step therefore fails here, exactly as it
# would on a real host with no node_modules tree.
write_fake_bun() {
  local path=$1 log=$2
  mkdir -p "${path%/*}"
  cat >"$path" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "\$0" "\$PWD" "\$*" >>"$log"
case "\${1-}" in
  install)
    mkdir -p "\$PWD/node_modules/smol-toml"
    ;;
  build)
    if [[ ! -d "\$PWD/../node_modules/smol-toml" ]]; then
      printf 'error: Could not resolve: "smol-toml"\n' >&2
      exit 1
    fi
    mkdir -p "\$PWD/dist"
    printf '#!/usr/bin/env bash\nexit 0\n' >"\$PWD/dist/settings-reconcile"
    chmod 0755 "\$PWD/dist/settings-reconcile"
    ;;
esac
exit 0
EOF
  chmod 0755 "$path"
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

# mise wins whenever it is present, even with a bun beside it: the mise path is
# the one the frozen hard-error boundaries describe.
prepare_case mise-wins-over-bun
printf old-executable >"$target"; chmod 0755 "$target"
sandbox_tools
write_fake_bun "$home_dir/.local/bin/bun" "$case_dir/bun-log"
env HOME="$home_dir" PATH="$fake_bin" /usr/bin/bash "$case_dir/build.sh" \
  >"$case_dir/stdout" 2>"$case_dir/stderr"
grep -F 'build-settings-reconcile: staged settings-reconcile' "$case_dir/stdout" >/dev/null
[[ ! -e "$case_dir/bun-log" ]] || {
  printf 'mise-wins-over-bun invoked bun: %s\n' "$(cat "$case_dir/bun-log")" >&2
  exit 1
}

# The R6 case. No mise, a bun only in the command staging directory, and no
# packages/node_modules: the script must run `bun install` in packages/ before
# it compiles, or the compile cannot resolve smol-toml.
prepare_case bun-only-no-node-modules
printf old-executable >"$target"; chmod 0755 "$target"
rm "$fake_bin/mise"
sandbox_tools
write_fake_bun "$home_dir/.local/share/chezmoi-commands/incomplete/bun/bun" "$case_dir/bun-log"
[[ ! -d "$source_dir/packages/node_modules" ]]
env HOME="$home_dir" PATH="$fake_bin" /usr/bin/bash "$case_dir/build.sh" \
  >"$case_dir/stdout" 2>"$case_dir/stderr" || {
  printf 'bun-only-no-node-modules failed\n' >&2
  cat "$case_dir/stderr" >&2
  exit 1
}
grep -F 'build-settings-reconcile: staged settings-reconcile' "$case_dir/stdout" >/dev/null
[[ $(cat "$target") != old-executable ]] || {
  printf 'bun-only-no-node-modules left the older executable in place\n' >&2
  exit 1
}
bun_log_expected=$(printf '%s\t%s\t%s\n%s\t%s\t%s\n' \
  "$home_dir/.local/share/chezmoi-commands/incomplete/bun/bun" \
  "$source_dir/packages" 'install --frozen-lockfile' \
  "$home_dir/.local/share/chezmoi-commands/incomplete/bun/bun" \
  "$source_dir/packages/settings-reconcile" \
  'build --compile ./src/cli.ts --outfile ./dist/settings-reconcile')
[[ $(cat "$case_dir/bun-log") == "$bun_log_expected" ]] || {
  printf 'bun-only-no-node-modules invoked bun as:\n%s\nexpected:\n%s\n' \
    "$(cat "$case_dir/bun-log")" "$bun_log_expected" >&2
  exit 1
}

prepare_case missing-toolchain
printf old-executable >"$target"; chmod 0755 "$target"
rm "$fake_bin/mise"
ln -s "$(command -v mkdir)" "$fake_bin/mkdir"
env HOME="$home_dir" PATH="$fake_bin" /usr/bin/bash "$case_dir/build.sh" \
  >"$case_dir/stdout" 2>"$case_dir/stderr"
grep -F 'build-settings-reconcile: neither mise nor bun is installed; settings-reconcile build is deferred' "$case_dir/stdout" >/dev/null
[[ -f "$home_dir/.local/state/chezmoi/skips/build-settings-reconcile__mise-and-bun-absent" ]]
[[ $(cat "$target") == old-executable ]]

prepare_case unsafe-target
mkdir "$target"
env HOME="$home_dir" PATH="$fake_bin:$PATH" bash "$case_dir/build.sh" \
  >"$case_dir/stdout" 2>"$case_dir/stderr"
[[ -d "$target" ]]
grep -F 'the settings-reconcile install target is not a regular file' "$case_dir/stdout" >/dev/null

printf 'build-settings-reconcile fatal-boundary, bun-path and target-safety tests passed\n'
