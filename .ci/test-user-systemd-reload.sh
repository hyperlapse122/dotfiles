#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_template=.chezmoiscripts/30-linux/run_after_reload-user-systemd.sh.tmpl
rendered_script=${1:-}
scratch=''

fail() {
  printf 'user-systemd-reload: FAIL: %s\n' "$*" >&2
  printf '%s\n' '--- stdout ---' >&2
  cat "$scratch/stdout" >&2 2>/dev/null || true
  printf '%s\n' '--- stderr ---' >&2
  cat "$scratch/stderr" >&2 2>/dev/null || true
  printf '%s\n' '--- systemctl calls ---' >&2
  if [[ -n ${systemctl_calls:-} ]]; then
    cat "$systemctl_calls" >&2 2>/dev/null || true
  fi
  exit 1
}

[[ $# -le 1 ]] || fail 'usage: test-user-systemd-reload.sh [RENDERED_SCRIPT]'

# shellcheck source=.ci/lib/render-scratch.sh
source "$repo_root/.ci/lib/render-scratch.sh"
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"
setup_render_scratch user-systemd-reload
chezmoi_bin=$(command -v chezmoi) || fail 'chezmoi is required to run this guard'
mkdir -p -- "$scratch/home"

[[ -f "$repo_root/$source_template" ]] || fail "missing source surface $source_template"

if [[ -z $rendered_script ]]; then
  rendered_script="$scratch/user-systemd-reload.sh"
  render "$repo_root" "$scratch" "$chezmoi_bin" linux \
    "$repo_root/$source_template" "$rendered_script" \
    || fail 'the Linux template did not render'
fi
[[ -f $rendered_script ]] || fail "missing rendered script $rendered_script"
[[ -s $rendered_script ]] || fail 'the Linux render is empty'
bash -n "$rendered_script" || fail 'the rendered Linux script is not valid shell'

darwin_render="$scratch/user-systemd-reload-darwin.sh"
render "$repo_root" "$scratch" "$chezmoi_bin" darwin \
  "$repo_root/$source_template" "$darwin_render" \
  || fail 'the Darwin template did not render'
[[ ! -s $darwin_render ]] || fail 'the template rendered a script on Darwin'

bin="$scratch/bin"
fixture_home="$scratch/fixture-home"
fixture_state="$scratch/fixture-state"
systemctl_calls="$scratch/systemctl.log"
mkdir -p -- "$bin" "$fixture_home" "$fixture_state"

cat >"$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$SYSTEMCTL_CALLS"
case "$*" in
  '--user show-environment')
    case "${FIXTURE_SHOW_MODE:-success}" in
      success) exit 0 ;;
      fail) exit 1 ;;
      hang) exec sleep "${FIXTURE_HANG_SECS:-30}" ;;
      *) exit 1 ;;
    esac
    ;;
  '--user daemon-reload')
    [[ "${FIXTURE_RELOAD_MODE:-success}" == success ]]
    ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$bin/systemctl"

skip_file="$fixture_state/chezmoi/skips/reload-user-systemd__no-user-manager-bus"

reset_fixture() {
  : >"$systemctl_calls"
  rm -rf -- "$fixture_state/chezmoi"
}

run_script() {
  local mode=$1 deadline=$2
  env HOME="$fixture_home" XDG_STATE_HOME="$fixture_state" \
    PATH="$bin:/usr/bin:/bin" SYSTEMCTL_CALLS="$systemctl_calls" \
    FIXTURE_SHOW_MODE="$mode" CAPABILITY_PROBE_DEADLINE_SECS="$deadline" \
    CAPABILITY_PROBE_TERM_GRACE_SECS=1 FIXTURE_RELOAD_MODE=success \
    bash "$rendered_script" \
    >"$scratch/stdout" 2>"$scratch/stderr" </dev/null
}

reload_count() {
  grep -cFx -- '--user daemon-reload' "$systemctl_calls" || true
}

assert_declared_skip() {
  [[ -f $skip_file ]] || fail 'the no-bus path wrote no declared skip record'
  grep -qF $'v1\treload-user-systemd\tno-user-manager-bus\ttransient-blocking:user-manager-bus-present\t' \
    "$skip_file" || fail 'the no-bus path wrote an unexpected skip record'
  grep -qF 'Recorded as done; it re-runs automatically once user-manager-bus-present changes.' \
    "$scratch/stdout" || fail 'the no-bus path did not emit its declared skip message'
}

reset_fixture
run_script success 5 || fail 'a responsive user manager caused the script to fail'
[[ $(grep -cFx -- '--user show-environment' "$systemctl_calls" || true) -eq 1 ]] \
  || fail 'the responsive case did not probe the user manager exactly once'
[[ $(reload_count) -eq 1 ]] \
  || fail "the responsive case did not reload exactly once: $(cat "$systemctl_calls")"
[[ ! -e $skip_file ]] || fail 'the responsive case wrote a skip record'

reset_fixture
run_script fail 5 || fail 'a failed user-manager probe caused the script to fail'
[[ $(reload_count) -eq 0 ]] || fail 'the failed probe still called daemon-reload'
assert_declared_skip

reset_fixture
started=$SECONDS
run_script hang 1 || fail 'a timed-out user-manager probe caused the script to fail'
elapsed=$((SECONDS - started))
(( elapsed <= 4 )) || fail "the timed-out probe exceeded its bound (${elapsed}s)"
[[ $(reload_count) -eq 0 ]] || fail 'the timed-out probe still called daemon-reload'
assert_declared_skip

printf 'user-systemd-reload: PASS\n'
