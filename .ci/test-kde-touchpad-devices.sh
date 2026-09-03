#!/usr/bin/env bash
# Drive the KDE touchpad reconciler against a STUB DEVICE SET.
#
# The reconciler walks org.kde.KWin.InputDeviceManager and decides per device
# what it is and which properties it may write. Until this harness existed
# nothing exercised that walk at all, and two defects reached review through the
# gap: an over-broad TrackPoint match that claimed every mouse on the host, and a
# scrollOnButtonDown guard that read the property's VALUE instead of the device's
# supports* capability, so its not-supported branch was dead code.
#
# Both are properties of the device set, not of one property read, so the fixture
# is a stub `busctl` serving a declared device table. The rendered script is real:
# only FACT_DESKTOP is rewritten, because a CI runner has no Plasma session and
# the guard would otherwise exit before the walk.
set -euo pipefail

usage='usage: test-kde-touchpad-devices.sh [RENDERED_SCRIPT]'
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
template='.chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-touchpad.sh.tmpl'

scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-$HOME/.cache}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/kde-touchpad-devices.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'test-kde-touchpad-devices: FAIL: %s\n' "$*" >&2; exit 1; }

# Render the script when the caller did not hand one over, using the same stub-op
# isolation AGENTS.md prescribes: renders resolve secrets live.
rendered=${1-}
if [[ -z $rendered ]]; then
  command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is required on PATH, or pass a rendered script'
  mkdir -p "$scratch/render-home" "$scratch/render-bin" "$scratch/render-target"
  printf '[data]\n' >"$scratch/render.toml"
  printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' \
    >"$scratch/render-bin/op"
  chmod 0700 "$scratch/render-bin/op"
  rendered="$scratch/rendered.sh"
  env HOME="$scratch/render-home" PATH="$scratch/render-bin:$PATH" \
    chezmoi --config "$scratch/render.toml" --source "$repo_root" \
    --destination "$scratch/render-target" execute-template \
    <"$repo_root/$template" >"$rendered" \
    || fail "$usage -- rendering $template failed"
fi
[[ -s $rendered ]] || fail "rendered script is empty: $rendered"

# The value probe this harness exists to keep retired. A capability guard reads a
# supports* property; a value probe reads the setting itself and always passes.
if grep -Eq '\-n "\$\(_dbus_get "\$path" scrollOnButtonDown\)"' "$rendered"; then
  fail 'the scrollOnButtonDown write must be gated on supportsScrollOnButtonDown, not on the property value'
fi
grep -Fq 'supportsScrollOnButtonDown' "$rendered" \
  || fail 'the rendered script names no supportsScrollOnButtonDown capability probe'

# FACT_DESKTOP is the only rewrite: kde-guard exits before the device walk on a
# host with no Plasma shell, which is every CI runner.
sed -E 's/^([[:space:]]*)FACT_DESKTOP=.*/\1FACT_DESKTOP=kde/' "$rendered" >"$scratch/script.sh"
grep -Eqx '[[:space:]]*FACT_DESKTOP=kde' "$scratch/script.sh" \
  || fail 'the rendered script carries no FACT_DESKTOP assignment to rewrite'

mkdir -p "$scratch/bin" "$scratch/home"

# The stub serves one device table from $DEVICE_TABLE, one record per line:
#   <sysname> <TAB> <property> <TAB> <value>
# and appends every set-property call to $SET_LOG. `name` is served quoted, the
# way busctl prints an `s` property, so the caller's dequoting is exercised too.
cat >"$scratch/bin/busctl" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
op=${1-}; shift || true
[[ $op == --user ]] || exit 1
op=${1-}; shift || true
case "$op" in
  get-property)
    # <service> <path> <interface> <property>
    path=$2; prop=$4
    if [[ $path == */org/kde/KWin/InputDevice ]] || [[ $path == /org/kde/KWin/InputDevice ]]; then
      if [[ $prop == devicesSysNames ]]; then
        names=$(cut -f1 "$DEVICE_TABLE" | awk '!seen[$0]++')
        count=$(printf '%s\n' "$names" | grep -c . || true)
        printf 'as %s' "$count"
        while IFS= read -r n; do [[ -n $n ]] && printf ' "%s"' "$n"; done <<<"$names"
        printf '\n'
        exit 0
      fi
      exit 1
    fi
    sysname=${path##*/}
    value=$(awk -F'\t' -v s="$sysname" -v p="$prop" '$1==s && $2==p { print $3; found=1 } END { exit !found }' \
      "$DEVICE_TABLE") || exit 1
    case "$prop" in
      name) printf 's "%s"\n' "$value" ;;
      tapFingerCount) printf 'u %s\n' "$value" ;;
      *) printf 'b %s\n' "$value" ;;
    esac
    ;;
  set-property)
    # <service> <path> <interface> <property> <signature> <value>
    printf '%s\t%s\t%s\n' "${2##*/}" "$4" "$6" >>"$SET_LOG"
    ;;
  *) exit 1 ;;
esac
exit 0
STUB
chmod 0755 "$scratch/bin/busctl"

# $1 = device table content. Prints the reconciler's stdout; $SET_LOG holds the
# writes. HOME is redirected because the declared skips inside the walk clear
# their own state entry under $XDG_STATE_HOME.
run_walk() {
  : >"$scratch/set.log"
  printf '%s' "$1" >"$scratch/devices.tsv"
  env HOME="$scratch/home" XDG_STATE_HOME="$scratch/home/state" \
    PATH="$scratch/bin:$PATH" DEVICE_TABLE="$scratch/devices.tsv" \
    SET_LOG="$scratch/set.log" \
    bash "$scratch/script.sh" 2>&1
}

wrote() { awk -F'\t' -v d="$1" -v p="$2" '$1==d && $2==p { found=1 } END { exit !found }' "$scratch/set.log"; }

tab=$'\t'
device_row() { printf '%s%s%s%s%s\n' "$1" "$tab" "$2" "$tab" "$3"; }

# A full TrackPoint, capability-complete. Its name matches the shipped
# kde.trackpoint.matchDevices glob for a TPPS/2 device.
trackpoint_supported=$(
  device_row event17 name 'TPPS/2 Elan TrackPoint'
  device_row event17 touchpad false
  device_row event17 pointer true
  device_row event17 supportsNaturalScroll true
  device_row event17 supportsMiddleEmulation true
  device_row event17 supportsScrollOnButtonDown true
)

# The same TrackPoint on hardware that exposes the property but cannot do it.
trackpoint_unsupported=$(
  device_row event17 name 'TPPS/2 Elan TrackPoint'
  device_row event17 touchpad false
  device_row event17 pointer true
  device_row event17 supportsNaturalScroll true
  device_row event17 supportsMiddleEmulation true
  device_row event17 supportsScrollOnButtonDown false
  device_row event17 scrollOnButtonDown true
)

# An ordinary mouse: a pointer, not a touchpad, matching no glob.
plain_mouse=$(
  device_row event15 name 'Logitech USB Receiver Mouse'
  device_row event15 touchpad false
  device_row event15 pointer true
  device_row event15 supportsNaturalScroll true
  device_row event15 supportsMiddleEmulation true
  device_row event15 supportsScrollOnButtonDown true
)

touchpad=$(
  device_row event16 name 'Synaptics TM3471-020'
  device_row event16 touchpad true
  device_row event16 pointer true
  device_row event16 supportsNaturalScroll true
  device_row event16 tapFingerCount 3
  device_row event16 supportsClickMethodClickfinger true
  device_row event16 supportsClickMethodAreas true
)

# A keyboard: neither touchpad nor pointer. It must not be reported or written.
keyboard=$(
  device_row event3 name 'AT Translated Set 2 keyboard'
  device_row event3 touchpad false
  device_row event3 pointer false
)

# --- A matched TrackPoint that declares support takes the write --------------
out=$(run_walk "$trackpoint_supported")
grep -Fq 'trackpoint: TPPS/2 Elan TrackPoint (event17)' <<<"$out" \
  || fail "a matched TrackPoint was not reported as one; output was:${tab}$out"
wrote event17 scrollOnButtonDown \
  || fail 'a device declaring supportsScrollOnButtonDown did not receive the write'
wrote event17 naturalScroll || fail 'a supported naturalScroll was not written'
wrote event17 middleEmulation || fail 'a supported middleEmulation was not written'

# --- A matched TrackPoint that declares NO support is skipped ---------------
# This is the assertion the value probe could never satisfy: scrollOnButtonDown
# reads `true` here, so a value probe writes anyway and the else branch is dead.
out=$(run_walk "$trackpoint_unsupported")
grep -Fq 'skip scrollOnButtonDown: not supported by device' <<<"$out" \
  || fail "an unsupported scrollOnButtonDown did not take the not-supported branch; output was:${tab}$out"
if wrote event17 scrollOnButtonDown; then
  fail 'a device that does not support scrollOnButtonDown was written to anyway'
fi
wrote event17 naturalScroll \
  || fail 'the unsupported scrollOnButtonDown must not suppress the other supported writes'

# --- An ordinary mouse is reported and left alone ---------------------------
out=$(run_walk "$plain_mouse")
grep -Fq 'no kde.trackpoint.matchDevices pattern matches it' <<<"$out" \
  || fail "an unmatched pointer was not reported as skipped; output was:${tab}$out"
if [[ -s "$scratch/set.log" ]]; then
  fail "an ordinary mouse received property writes: $(cat "$scratch/set.log")"
fi

# --- A touchpad is configured as a touchpad ---------------------------------
out=$(run_walk "$touchpad")
grep -Fq 'touchpad: Synaptics TM3471-020 (event16)' <<<"$out" \
  || fail "a touchpad was not reported as one; output was:${tab}$out"
wrote event16 naturalScroll || fail 'a touchpad naturalScroll was not written'
wrote event16 tapToClick || fail 'a touchpad tapToClick was not written'
wrote event16 clickMethodClickfinger || fail 'a touchpad clickMethodClickfinger was not written'
if wrote event16 middleEmulation; then
  fail 'a touchpad must not receive the TrackPoint property set'
fi

# --- A device that is neither is never touched ------------------------------
out=$(run_walk "$keyboard")
if [[ -s "$scratch/set.log" ]]; then
  fail "a keyboard received property writes: $(cat "$scratch/set.log")"
fi
grep -Fq 'no touchpad or trackpoint is present in this session' <<<"$out" \
  || fail "a device set with no pointer device did not declare the no-target skip; output was:${tab}$out"

# --- The whole host set at once ---------------------------------------------
out=$(run_walk "$touchpad
$trackpoint_supported
$plain_mouse
$keyboard")
wrote event16 clickMethodClickfinger || fail 'the mixed device set skipped the touchpad'
wrote event17 scrollOnButtonDown || fail 'the mixed device set skipped the TrackPoint'
if wrote event15 naturalScroll; then
  fail 'the mixed device set claimed an ordinary mouse'
fi
grep -Fq 'configured 2 touchpad(s).' <<<"$out" \
  || fail "the mixed device set did not report two configured devices; output was:${tab}$out"

printf 'test-kde-touchpad-devices: all device-set assertions passed\n'
