#!/usr/bin/env bash
set -euo pipefail

# Drives the rendered .chezmoiscripts/00-tools/run_onchange_after_android-sdk.sh.tmpl
# against a stubbed `android` CLI.
#
# WHY A STUB. The real CLI downloads gigabytes from Google's SDK repository and
# needs a working SDK on disk; no runner has either. So this gate renders the
# template and drives the rendered script with a stub on PATH, the same way
# .ci/test-orca-register.sh drives its helper — the script's decisions are what
# is under test, not the SDK.
#
# WHAT IS PINNED. The three properties the script is named for, each of which
# fails silently if it regresses:
#   - a missing `android` CLI aborts instead of finishing green with no SDK
#   - a failing `emulator list` aborts instead of reading as "no AVD exists"
#   - the AVD is created only when none exists, so a re-render displaces nothing
# Plus the ABI composition and the container gate, which are render-time.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
template="$repo_root/.chezmoiscripts/00-tools/run_onchange_after_android-sdk.sh.tmpl"

fail() {
  printf 'test-android-sdk-provision: %s\n' "$*" >&2
  exit 1
}

pass() { printf '  ok  %s\n' "$*"; }

[ -f "$template" ] || fail "template not found at .chezmoiscripts/00-tools/run_onchange_after_android-sdk.sh.tmpl"
command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is not on PATH'

scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/android-sdk-provision.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

printf '[data]\n' >"$scratch/empty.toml"
mkdir -p "$scratch/target" "$scratch/render-home"

# No secret tooling is involved: this template reads only host facts and the
# release lock, so the render runs with an empty environment and a bare PATH.
# Nothing here stands in for a credential store.
render() {
  env -i HOME="$scratch/render-home" PATH="/usr/bin:/bin" \
    chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
    --destination "$scratch/target" execute-template <"$template"
}

rendered="$scratch/android-sdk.sh"
render >"$rendered"
[ -s "$rendered" ] || fail 'template rendered empty on this host'

# --- render-time properties --------------------------------------------------

bash -n "$rendered" || fail 'rendered script is not valid bash'
pass 'the rendered script parses'

grep -q 'system-images/android-36/google_apis/' "$rendered" ||
  fail 'rendered script installs no API 36 google_apis system image'
grep -qE 'system-images/android-36/google_apis/(x86_64|arm64-v8a)' "$rendered" ||
  fail 'system image ABI is neither x86_64 nor arm64-v8a'
pass 'the system image ABI is composed for the host architecture'

for component in cmdline-tools emulator platform-tools; do
  grep -q "\"$component\"" "$rendered" || fail "rendered script does not install $component"
done
pass 'cmdline-tools, emulator and platform-tools are all installed'

grep -q '|| true' "$rendered" && fail 'rendered script still swallows a failure with || true'
pass 'no step swallows its failure'

# --- runtime behavior, driven with a stub ------------------------------------

make_stub() {
  stub_dir="$scratch/stub.$1"
  mkdir -p "$stub_dir/bin"
  cat >"$stub_dir/bin/android" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ANDROID_STUB_LOG"
for word in "$@"; do
  case "$word" in
    list) [ -f "$ANDROID_STUB_DIR/list.fails" ] && { echo 'stub: emulator list exploded' >&2; exit 3; }
          cat "$ANDROID_STUB_DIR/avds"; exit 0 ;;
    create) [ -f "$ANDROID_STUB_DIR/create.fails" ] && { echo 'stub: create exploded' >&2; exit 4; }
            exit 0 ;;
    install) [ -f "$ANDROID_STUB_DIR/install.fails" ] && { echo 'stub: install exploded' >&2; exit 5; }
             exit 0 ;;
  esac
done
exit 0
STUB
  chmod +x "$stub_dir/bin/android"
  export ANDROID_STUB_DIR="$stub_dir"
  export ANDROID_STUB_LOG="$stub_dir/log"
  : >"$ANDROID_STUB_LOG"
  : >"$stub_dir/avds"
  stub_path="$stub_dir/bin"
}

# HERMETIC BY CONSTRUCTION. PATH is the stub directory ALONE plus the coreutils
# the script needs — never the ambient PATH. The script falls back to
# `command -v android` when $HOME/.local/bin/android is absent, so an inherited
# PATH lets the missing-CLI case find the operator's real android CLI and run
# `init` and `sdk install` for real: gigabytes downloaded and managed skill
# files overwritten, from a test whose whole point is that no CLI exists.
run_script() {
  set +e
  script_out=$(env -i \
    HOME="$scratch/home" \
    ANDROID_HOME="$scratch/sdk" ANDROID_SDK_ROOT="$scratch/sdk" \
    ANDROID_STUB_DIR="$ANDROID_STUB_DIR" ANDROID_STUB_LOG="$ANDROID_STUB_LOG" \
    PATH="$stub_path:/usr/bin:/bin" \
    bash "$rendered" 2>&1)
  script_rc=$?
  set -e
}

mkdir -p "$scratch/home" "$scratch/sdk"

# Prove the isolation before relying on it: if a run could see the operator's
# real android CLI, every case below would drive the real SDK instead of a stub.
make_stub isolation-probe
rm -f "$stub_path/android"
probe=$(env -i HOME="$scratch/home" PATH="$stub_path:/usr/bin:/bin" \
  bash -c 'command -v android || echo NONE')
[ "$probe" = NONE ] || fail "the harness can reach a real android CLI at $probe"
pass 'no real android CLI is reachable from inside a run'

# A missing CLI must abort, not finish green with no SDK.
make_stub missing-cli
rm -f "$stub_path/android"
run_script
[ "$script_rc" -ne 0 ] || fail 'a missing android CLI exited zero'
case "$script_out" in *'android CLI'*) : ;; *) fail "error did not name the missing CLI: $script_out" ;; esac
pass 'a missing android CLI aborts the apply naming it'

# A failing component install must abort.
make_stub install-fails
: >"$ANDROID_STUB_DIR/install.fails"
run_script
[ "$script_rc" -ne 0 ] || fail 'a failing sdk install exited zero'
pass 'a failing sdk install aborts the apply'

# A failing AVD probe must abort, not read as "no AVD exists".
make_stub list-fails
: >"$ANDROID_STUB_DIR/list.fails"
run_script
[ "$script_rc" -ne 0 ] || fail 'a failing emulator list exited zero'
grep -q 'emulator create' "$ANDROID_STUB_LOG" && fail 'a failing emulator list still created an AVD'
case "$script_out" in *'emulator list'*) : ;; *) fail "error did not name the failing probe: $script_out" ;; esac
pass 'a failing emulator list aborts instead of reading as no-AVD'

# No AVD -> create exactly one.
make_stub no-avd
run_script
[ "$script_rc" -eq 0 ] || fail "no-AVD run exited $script_rc: $script_out"
grep -q 'emulator create medium_phone' "$ANDROID_STUB_LOG" || fail 'no AVD present but none was created'
pass 'an empty device list creates the default AVD'

# An operator's own AVD is never displaced.
make_stub existing-avd
printf 'Pixel_7_API_36\n' >"$ANDROID_STUB_DIR/avds"
run_script
[ "$script_rc" -eq 0 ] || fail "existing-AVD run exited $script_rc: $script_out"
grep -q 'emulator create' "$ANDROID_STUB_LOG" && fail 'an existing AVD was displaced by a new one'
pass 'an existing AVD is left alone'

# A failing create must abort naming the profile.
make_stub create-fails
: >"$ANDROID_STUB_DIR/create.fails"
run_script
[ "$script_rc" -ne 0 ] || fail 'a failing emulator create exited zero'
case "$script_out" in *medium_phone*) : ;; *) fail "error did not name the profile: $script_out" ;; esac
pass 'a failing AVD creation aborts naming the profile'

printf 'test-android-sdk-provision: all checks passed\n'
