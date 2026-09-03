#!/usr/bin/env bash
# Prove the hook's hardware probes discriminate what they claim to.
#
# These four probes decide whether a host receives laptop power behaviour, hybrid
# graphics driver options, an authentication factor, and a greeter retirement.
# Each one is a sysfs walk in .install-prerequisites.sh, which runs before the
# source state and cannot be exercised by a render test — so the functions are
# sourced here and driven against synthetic sysfs trees.
#
# The battery case is the sharp one. A wireless mouse registers an ordinary power
# supply, and this fleet already runs a mouse-battery watcher on desktops, so a
# probe keyed on `type == Battery` alone would hand every such desktop the laptop
# sleep policy.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/host-fact-probes.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() {
  printf 'host-fact-probes: FAIL: %s\n' "$*" >&2
  exit 1
}

# Source only the probe functions, not the hook's top-level bootstrap.
probes="$scratch/probes.sh"
sed -n '/^fact_hybrid_graphics()/,/^}/p;/^fact_battery()/,/^}/p;/^fact_fingerprint_reader()/,/^}/p;/^fact_display_manager()/,/^}/p;/^fact_gpu_device_id()/,/^}/p' \
  "$repo_root/.install-prerequisites.sh" >"$probes"
grep -q '^fact_battery()' "$probes" || fail 'fact_battery was not extracted from the hook'
grep -q '^fact_hybrid_graphics()' "$probes" || fail 'fact_hybrid_graphics was not extracted from the hook'
# shellcheck disable=SC1090
. "$probes"

# --- Synthetic sysfs -------------------------------------------------------
# The probes read absolute paths, so each case builds its tree under a fake root
# and the probe body is re-sourced with those paths rewritten to it.
run_probe_under() {
  local root=$1 fn=$2 rewritten="$scratch/rewritten.sh"
  sed "s#/sys/#${root}/sys/#g" "$probes" >"$rewritten"
  # shellcheck disable=SC1090
  ( . "$rewritten"; "$fn" >/dev/null 2>&1 )
}

make_supply() {
  local root=$1 name=$2 type=$3 scope=${4:-}
  mkdir -p "$root/sys/class/power_supply/$name"
  printf '%s\n' "$type" >"$root/sys/class/power_supply/$name/type"
  [[ -n "$scope" ]] && printf '%s\n' "$scope" >"$root/sys/class/power_supply/$name/scope"
  return 0
}

make_pci() {
  local root=$1 slot=$2 vendor=$3 class=$4 device=${5:-0x0000}
  mkdir -p "$root/sys/bus/pci/devices/$slot"
  printf '%s\n' "$vendor" >"$root/sys/bus/pci/devices/$slot/vendor"
  printf '%s\n' "$class" >"$root/sys/bus/pci/devices/$slot/class"
  printf '%s\n' "$device" >"$root/sys/bus/pci/devices/$slot/device"
}

# --- battery ---------------------------------------------------------------
laptop="$scratch/laptop"
make_supply "$laptop" AC Mains
make_supply "$laptop" BAT0 Battery
run_probe_under "$laptop" fact_battery \
  || fail 'a chassis battery with no scope attribute must resolve battery=true'

laptop_scoped="$scratch/laptop-scoped"
make_supply "$laptop_scoped" BAT0 Battery System
run_probe_under "$laptop_scoped" fact_battery \
  || fail 'a chassis battery with scope=System must resolve battery=true'

desktop_mouse="$scratch/desktop-mouse"
make_supply "$desktop_mouse" AC Mains
make_supply "$desktop_mouse" hidpp_battery_0 Battery Device
run_probe_under "$desktop_mouse" fact_battery \
  && fail 'a desktop whose only battery is a peripheral must resolve battery=false'

desktop_plain="$scratch/desktop-plain"
make_supply "$desktop_plain" AC Mains
run_probe_under "$desktop_plain" fact_battery \
  && fail 'a desktop with no battery at all must resolve battery=false'

mixed="$scratch/mixed"
make_supply "$mixed" BAT0 Battery
make_supply "$mixed" hidpp_battery_0 Battery Device
run_probe_under "$mixed" fact_battery \
  || fail 'a laptop with a peripheral battery too must still resolve battery=true'

# --- hybrid graphics -------------------------------------------------------
optimus="$scratch/optimus"
make_pci "$optimus" 0000:00:02.0 0x8086 0x030000 0x9b41
make_pci "$optimus" 0000:2d:00.0 0x10de 0x030200 0x1d34
run_probe_under "$optimus" fact_hybrid_graphics \
  || fail 'an integrated GPU alongside an NVIDIA one must resolve hybridGraphics=true'

discrete_only="$scratch/discrete-only"
make_pci "$discrete_only" 0000:01:00.0 0x10de 0x030000 0x2704
run_probe_under "$discrete_only" fact_hybrid_graphics \
  && fail 'a single discrete NVIDIA GPU must resolve hybridGraphics=false'

igpu_only="$scratch/igpu-only"
make_pci "$igpu_only" 0000:00:02.0 0x8086 0x030000 0x9b41
run_probe_under "$igpu_only" fact_hybrid_graphics \
  && fail 'an integrated GPU with no discrete card must resolve hybridGraphics=false'

# An NVIDIA audio function on the same card is class 0x0403, not a display
# device, and must not be mistaken for a second GPU.
audio_fn="$scratch/audio-fn"
make_pci "$audio_fn" 0000:01:00.0 0x10de 0x030000 0x2704
make_pci "$audio_fn" 0000:01:00.1 0x10de 0x040300 0x22bc
run_probe_under "$audio_fn" fact_hybrid_graphics \
  && fail 'an NVIDIA audio function must not make a single-GPU host look hybrid'

# --- gpu device id ---------------------------------------------------------
got=$( sed "s#/sys/#${optimus}/sys/#g" "$probes" >"$scratch/r.sh"; . "$scratch/r.sh"; fact_gpu_device_id )
[[ "$got" == '1d34' ]] || fail "expected the NVIDIA display device id 1d34, probe returned '${got:-<empty>}'"

got=$( sed "s#/sys/#${audio_fn}/sys/#g" "$probes" >"$scratch/r.sh"; . "$scratch/r.sh"; fact_gpu_device_id )
[[ "$got" == '2704' ]] || fail "the class filter must pick the display function, probe returned '${got:-<empty>}'"

got=$( sed "s#/sys/#${igpu_only}/sys/#g" "$probes" >"$scratch/r.sh"; . "$scratch/r.sh"; fact_gpu_device_id || true )
[[ -z "$got" ]] || fail "a host with no NVIDIA display device must yield no id, probe returned '$got'"

printf 'host-fact-probes: OK\n'
