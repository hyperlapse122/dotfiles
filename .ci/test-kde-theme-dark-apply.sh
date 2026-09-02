#!/usr/bin/env bash
#
# test-kde-theme-dark-apply.sh — behavioural gate for config-kde-theme-dark's
# ONE piece of real logic: decide whether the Breeze Dark colour scheme still
# needs applying, then apply it exactly once.
#
# WHY THIS TEST EXISTS. The skip-declaration audit and the capability-cache
# fixture both check this script's *shape* — that its four guards are declared
# and accounted for. Neither executes it. Inverting the idempotence comparison
# (`==` -> `!=`) leaves both of those green while defeating the feature, so the
# act path needs a gate of its own. That is what this file is.
#
# THE REGRESSION IT PINS. The guard must compare a PAINTED value, never the
# [General] ColorScheme label: kreadconfig6 resolves that label through the
# KConfig cascade, so ~/.config/kdedefaults/kdeglobals answers it even when the
# user file carries no such key. Case `label-set-colours-light` below seeds
# exactly that state — the label says BreezeDark, the colours are light — and
# asserts the scheme is still applied. A label-reading guard fails it.
#
# Fake binaries on PATH stand in for kreadconfig6 and plasma-apply-colorscheme,
# in the style of test-kde-calendar-hard-error.sh. The rendered script is passed
# in by CI, which renders it with the same stub-op recipe the other
# fatal-boundary gates use. Nothing here touches the real $HOME or a real Plasma.
set -euo pipefail

rendered=${1:?usage: test-kde-theme-dark-apply.sh RENDERED_SCRIPT}
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
scratch=$(mktemp -d "$scratch_root/kde-theme-dark-apply-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

DARK_BG='32,35,38'
LIGHT_BG='239,240,241'

failures=0

fail() {
  printf '::error::test-kde-theme-dark-apply: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Build one case: a fake HOME, fake binaries, and a copy of the rendered script
# with the KDE fact and the live-session guards forced to the "session present"
# answer so the act path is reachable.
#
# $1 case name, $2 value the fake kreadconfig6 reports for the USER file's
# painted BackgroundNormal (empty means "key absent").
prepare_case() {
  local name=$1 user_bg=$2
  case_dir="$scratch/$name"
  home_dir="$case_dir/home"
  fake_bin="$case_dir/bin"
  mkdir -p "$home_dir" "$fake_bin"

  # kreadconfig6 stub. It answers the two reads the script makes and models the
  # cascade faithfully: the [General] ColorScheme LABEL always resolves to
  # BreezeDark (as it does on a real host via the kdedefaults layer), while the
  # painted [Colors:Window] BackgroundNormal is whatever this case seeds.
  cat >"$fake_bin/kreadconfig6" <<EOF
#!/usr/bin/env bash
file=""; group=""; key=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --file) file=\$2; shift 2 ;;
    --group) group=\$2; shift 2 ;;
    --key) key=\$2; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "\$group" == General && "\$key" == ColorScheme ]]; then
  printf 'BreezeDark\n'; exit 0
fi
if [[ "\$group" == Colors:Window && "\$key" == BackgroundNormal ]]; then
  case "\$file" in
    */color-schemes/*) printf '%s\n' '$DARK_BG'; exit 0 ;;
    *) printf '%s' '$user_bg'; [[ -n '$user_bg' ]] && printf '\n'; exit 0 ;;
  esac
fi
exit 1
EOF

  # plasma-apply-colorscheme stub: records each invocation's argv.
  cat >"$fake_bin/plasma-apply-colorscheme" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$case_dir/applied.log"
exit 0
EOF

  # plasmashell must look like it is running for the third guard to pass.
  cat >"$fake_bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod 0755 "$fake_bin"/kreadconfig6 "$fake_bin"/plasma-apply-colorscheme "$fake_bin"/pgrep
  : >"$case_dir/applied.log"

  sed 's/^[[:space:]]*FACT_DESKTOP=.*/  FACT_DESKTOP=kde/' "$rendered" >"$case_dir/theme-dark.sh"
  chmod 0755 "$case_dir/theme-dark.sh"
}

run_case() {
  set +e
  env HOME="$home_dir" PATH="$fake_bin:$PATH" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$case_dir/bus" \
    WAYLAND_DISPLAY="wayland-0" \
    USER="${USER:-runner}" \
    "$case_dir/theme-dark.sh" >"$case_dir/stdout" 2>"$case_dir/stderr"
  status=$?
  set -e
}

applied_count() { wc -l <"$case_dir/applied.log" | tr -d '[:space:]'; }

# --- Case 1: colours already dark -> must NOT re-apply -----------------------
prepare_case already-dark "$DARK_BG"
run_case
(( status == 0 )) || fail "already-dark: expected exit 0, got $status"
[[ "$(applied_count)" == 0 ]] \
  || fail "already-dark: plasma-apply-colorscheme ran $(applied_count) time(s); it must not run when the painted colours already match"
grep -q 'already BreezeDark' "$case_dir/stdout" \
  || fail "already-dark: expected the script to report the scheme was already applied"

# --- Case 2: the regression this file exists for -----------------------------
# The cascade LABEL says BreezeDark while the painted colours are light. A guard
# that reads the label skips here and the desktop stays light forever.
prepare_case label-set-colours-light "$LIGHT_BG"
run_case
(( status == 0 )) || fail "label-set-colours-light: expected exit 0, got $status"
[[ "$(applied_count)" == 1 ]] \
  || fail "label-set-colours-light: plasma-apply-colorscheme ran $(applied_count) time(s), expected exactly 1 -- the guard is reading the cascade-resolved [General] ColorScheme label instead of a painted value"
grep -qx 'BreezeDark' "$case_dir/applied.log" \
  || fail "label-set-colours-light: expected the scheme applied to be exactly BreezeDark, got '$(cat "$case_dir/applied.log")'"

# --- Case 3: no painted colours recorded yet -> must apply -------------------
prepare_case colours-absent ""
run_case
(( status == 0 )) || fail "colours-absent: expected exit 0, got $status"
[[ "$(applied_count)" == 1 ]] \
  || fail "colours-absent: plasma-apply-colorscheme ran $(applied_count) time(s), expected exactly 1 when the user file has no painted value"

if (( failures > 0 )); then
  printf 'test-kde-theme-dark-apply: %d failure(s)\n' "$failures" >&2
  exit 1
fi

printf 'test-kde-theme-dark-apply: ok - applies only when the painted colours are not already %s\n' "$DARK_BG"
printf 'test-kde-theme-dark-apply: all tests passed\n'
