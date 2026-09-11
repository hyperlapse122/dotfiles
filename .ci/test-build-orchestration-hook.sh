#!/usr/bin/env bash
set -euo pipefail

# Guards the 60-build script that compiles and stages the orchestration hook.
#
# Like its sibling build gates, this one fabricates a dist artifact and a fake
# toolchain rather than compiling for real — .ci/test-orchestration-hook.sh owns
# the real binary's behavior. What this gate owns is the staging contract, which
# the binary's own tests cannot see:
#
#   - The build FAILS LOUDLY. Fail-open is the hook's property, never the
#     pipeline's: a build that converged on failure would leave the previous
#     binary in place and void the guarantee that one apply carries a rule edit
#     to the next session, with no signal anywhere.
#   - Staging is ATOMIC. A session that starts mid-copy would exec a truncated
#     file and get ENOEXEC, which is not a fail-open path — the hook's own code
#     never runs. The declared path must always hold a complete binary.

rendered=${1:?usage: test-build-orchestration-hook.sh RENDERED_SCRIPT}
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
scratch=$(mktemp -d "$scratch_root/orchestration-hook-build-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'build-orchestration-hook gate: %s\n' "$*" >&2; exit 1; }
pass() { printf 'build-orchestration-hook gate: %s\n' "$*"; }

prepare_case() {
  local name=$1
  case_dir="$scratch/$name"
  source_dir="$case_dir/source"
  home_dir="$case_dir/home"
  fake_bin="$case_dir/bin"
  mkdir -p "$source_dir/packages/orchestration-hook/dist" "$home_dir/.local/libexec" "$fake_bin"
  printf '#!/usr/bin/env bash\nprintf NEW\n' \
    >"$source_dir/packages/orchestration-hook/dist/orchestration-hook"
  chmod 0755 "$source_dir/packages/orchestration-hook/dist/orchestration-hook"
  cat >"$fake_bin/mise" <<'EOF'
#!/usr/bin/env bash
case "${ORCHESTRATION_HOOK_MISE_MODE:-success}:$*" in
  dependency:*'vp install --frozen-lockfile'*) exit 41 ;;
  build:*'vp run build'*) exit 42 ;;
esac
exit 0
EOF
  chmod 0755 "$fake_bin/mise"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin/bun"
  chmod 0755 "$fake_bin/bun"
  sed "s|^SRC=.*$|SRC=\"$source_dir\"|" "$rendered" >"$case_dir/build.sh"
  chmod 0755 "$case_dir/build.sh"
  target="$home_dir/.local/libexec/orchestration-hook"
}

run_case() {
  set +e
  env -i PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" \
    ORCHESTRATION_HOOK_MISE_MODE="${1:-success}" \
    bash "$case_dir/build.sh" >"$case_dir/out" 2>"$case_dir/err"
  status=$?
  set -e
}

# --------------------------------------------------------------- happy path
prepare_case success
run_case
(( status == 0 )) || fail "a healthy build must exit 0 (got $status): $(cat "$case_dir/err")"
[[ -x $target ]] || fail 'a healthy build must stage an executable binary'
[[ $(cat "$target") == *NEW* ]] || fail 'the staged binary is not the freshly built artifact'
[[ $(stat -c '%a' "$target") == 755 ]] || fail 'the staged binary must be mode 0755'
pass 'a healthy build stages the new artifact at 0755'

# No temporary left behind: the staging temp file is what makes the replace
# atomic, and a leaked one would accumulate in ~/.local/libexec on every apply.
leaked=$(find "$home_dir/.local/libexec" -maxdepth 1 -name '.orchestration-hook.*' | wc -l)
(( leaked == 0 )) || fail 'staging leaked a temporary file into ~/.local/libexec'
pass 'staging leaves no temporary behind'

# ------------------------------------------------------------- loud failures
for mode in dependency build; do
  prepare_case "fail-$mode"
  printf 'PREVIOUS\n' >"$target"
  chmod 0755 "$target"
  run_case "$mode"
  (( status != 0 )) || fail "a failed $mode step must abort the apply, not converge"
  [[ -s "$case_dir/err" ]] || fail "a failed $mode step must say why on stderr"
  # The previous binary survives a failed build. It is stale, which the apply
  # now reports loudly, but a host is never left with no hook at all.
  [[ $(cat "$target") == PREVIOUS ]] \
    || fail "a failed $mode step must leave the previously staged binary untouched"
  pass "a failed $mode step aborts the apply and leaves the previous binary intact"
done

# A missing dist artifact is the third loud path: the toolchain reported success
# but produced nothing, which must never reach staging.
prepare_case missing-dist
rm -f "$source_dir/packages/orchestration-hook/dist/orchestration-hook"
run_case
(( status != 0 )) || fail 'a build that produced no artifact must abort the apply'
[[ ! -e $target ]] || fail 'a build that produced no artifact must stage nothing'
pass 'a build that produced no artifact aborts before staging'

# An absent toolchain is loud too — never a silent skip, because a skipped build
# on a converged host is indistinguishable from a successful one.
prepare_case no-bun
rm -f "$fake_bin/bun"
run_case
(( status != 0 )) || fail 'an absent bun must abort the apply rather than skip'
grep -qi 'bun' "$case_dir/err" || fail 'the absent-bun diagnostic must name bun'
pass 'an absent toolchain aborts the apply and names what is missing'

prepare_case no-mise
rm -f "$fake_bin/mise"
run_case
(( status != 0 )) || fail 'an absent mise must abort the apply rather than skip'
grep -qi 'mise' "$case_dir/err" || fail 'the absent-mise diagnostic must name mise'
pass 'an absent mise aborts the apply and names what is missing'

printf 'build-orchestration-hook gate: all tests passed\n'
