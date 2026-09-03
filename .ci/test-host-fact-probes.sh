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
# scan_pci_bus and its PCI_* accumulators come along: the three PCI facts share
# one pass over the bus, so extracting them without it would leave the probes
# calling an undefined function.
{
  sed -n '/^PCI_SCAN_DONE=/,/^PCI_OTHER_DISPLAY=/p' "$repo_root/.install-prerequisites.sh"
  sed -n '/^scan_pci_bus()/,/^}/p' "$repo_root/.install-prerequisites.sh"
  sed -n '/^fact_nvidia()/,/^}/p;/^fact_hybrid_graphics()/,/^}/p;/^fact_battery()/,/^}/p;/^fact_fingerprint_reader()/,/^}/p;/^fact_display_manager()/,/^}/p;/^fact_gpu_device_id()/,/^}/p' \
    "$repo_root/.install-prerequisites.sh"
} >"$probes"
# Guard EVERY extracted function. An anchored sed range that matches nothing
# fails silently, so without these a rename or a restyling to `function fact_x()`
# would leave this file asserting against an empty extraction and still pass.
for fn in scan_pci_bus fact_nvidia fact_hybrid_graphics fact_gpu_device_id \
  fact_battery fact_fingerprint_reader fact_display_manager; do
  grep -q "^${fn}()" "$probes" || fail "${fn} was not extracted from the hook"
done
# shellcheck disable=SC1090
. "$probes"

# --- Synthetic sysfs -------------------------------------------------------
# The probes read absolute paths, so each case builds its tree under a fake root
# and the probe body is re-sourced with those paths rewritten to it.
# fact_display_manager reads /etc/systemd, not /sys, so the rewrite covers both
# roots -- without this a display-manager case would read the REAL runner's
# /etc and pass for the wrong reason.
relocate() {
  local root=$1 out=$2
  sed -e "s#/sys/#${root}/sys/#g" -e "s#/etc/systemd/#${root}/etc/systemd/#g" \
    "$probes" >"$out"
}

run_probe_under() {
  local root=$1 fn=$2 rewritten="$scratch/rewritten.sh"
  relocate "$root" "$rewritten"
  # shellcheck disable=SC1090
  ( . "$rewritten"; "$fn" >/dev/null 2>&1 )
}

# Same rewrite, but the probe's stdout is the answer rather than its exit status.
# A probe that legitimately reports nothing must yield the empty string, not kill
# the run under `set -e`.
probe_output_under() {
  local root=$1 fn=$2 rewritten="$scratch/rewritten.sh"
  relocate "$root" "$rewritten"
  # shellcheck disable=SC1090
  ( . "$rewritten"; "$fn" 2>/dev/null || true )
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
got="$(probe_output_under "$optimus" fact_gpu_device_id)"
[[ "$got" == '1d34' ]] || fail "expected the NVIDIA display device id 1d34, probe returned '${got:-<empty>}'"

got="$(probe_output_under "$audio_fn" fact_gpu_device_id)"
[[ "$got" == '2704' ]] || fail "the class filter must pick the display function, probe returned '${got:-<empty>}'"

got="$(probe_output_under "$igpu_only" fact_gpu_device_id)"
[[ -z "$got" ]] || fail "a host with no NVIDIA display device must yield no id, probe returned '$got'"

# --- fingerprint reader -----------------------------------------------------
# The probe resolves its table relative to the hook's own directory, so the
# relocated copy is written INTO the repo root's .ci and reads the real table.
make_usb() {
  local root=$1 dev=$2 vendor=$3 product=$4
  mkdir -p "$root/sys/bus/usb/devices/$dev"
  printf '%s\n' "$vendor" >"$root/sys/bus/usb/devices/$dev/idVendor"
  printf '%s\n' "$product" >"$root/sys/bus/usb/devices/$dev/idProduct"
}

listed_vendor=$(awk -F'\t' 'NR>1 {print $1; exit}' "$repo_root/.chezmoidata/.fingerprint-readers.tsv")
listed_product=$(awk -F'\t' 'NR>1 {print $2; exit}' "$repo_root/.chezmoidata/.fingerprint-readers.tsv")
[[ -n "$listed_vendor" && -n "$listed_product" ]] \
  || fail 'the fingerprint-reader table has no data row to test against'

fp_yes="$scratch/fp-yes"
make_usb "$fp_yes" 1-1 "$listed_vendor" "$listed_product"
make_usb "$fp_yes" 1-2 1d6b 0002
CHEZMOI_SOURCE_DIR="$repo_root" run_probe_under "$fp_yes" fact_fingerprint_reader \
  || fail 'a USB device listed in the reader table must resolve fingerprintReader=true'

fp_no="$scratch/fp-no"
make_usb "$fp_no" 1-1 1d6b 0002
make_usb "$fp_no" 1-2 8087 0026
CHEZMOI_SOURCE_DIR="$repo_root" run_probe_under "$fp_no" fact_fingerprint_reader \
  && fail 'a host with no listed reader must resolve fingerprintReader=false'

# A vendor id that matches but a product id that does not must NOT match: the
# table is a vendor/product PAIR, not a vendor allowlist.
fp_partial="$scratch/fp-partial"
make_usb "$fp_partial" 1-1 "$listed_vendor" ffff
CHEZMOI_SOURCE_DIR="$repo_root" run_probe_under "$fp_partial" fact_fingerprint_reader \
  && fail 'a matching vendor with a different product must not resolve fingerprintReader=true'

# --- display manager --------------------------------------------------------
# This is the probe that shipped reporting the fake name "display-manager":
# `readlink -f` succeeds on a missing path and prints the path back, so only a
# symlink-existence guard makes "no display manager" resolve to the empty value
# the registry declares.
make_dm() {
  local root=$1 unit=${2:-}
  mkdir -p "$root/etc/systemd/system"
  [[ -n "$unit" ]] && ln -sfn "/usr/lib/systemd/system/$unit" \
    "$root/etc/systemd/system/display-manager.service"
  return 0
}

dm_sddm="$scratch/dm-sddm"
make_dm "$dm_sddm" sddm.service
got="$(probe_output_under "$dm_sddm" fact_display_manager)"
[[ "$got" == 'sddm' ]] || fail "an sddm alias must resolve displayManager=sddm, probe returned '${got:-<empty>}'"

dm_gdm="$scratch/dm-gdm"
make_dm "$dm_gdm" gdm.service
got="$(probe_output_under "$dm_gdm" fact_display_manager)"
[[ "$got" == 'gdm' ]] || fail "a gdm alias must resolve displayManager=gdm, probe returned '${got:-<empty>}'"

dm_none="$scratch/dm-none"
make_dm "$dm_none"
got="$(probe_output_under "$dm_none" fact_display_manager)"
[[ -z "$got" ]] \
  || fail "a host with no display-manager alias must yield the empty value, probe returned '$got'"

# A DANGLING alias is the exact shape readlink -f reports success for.
dm_dangling="$scratch/dm-dangling"
mkdir -p "$dm_dangling/etc/systemd/system"
ln -sfn /usr/lib/systemd/system/does-not-exist.service \
  "$dm_dangling/etc/systemd/system/display-manager.service"
got="$(probe_output_under "$dm_dangling" fact_display_manager)"
[[ "$got" == 'does-not-exist' ]] \
  || fail "a dangling alias still names its unit, probe returned '${got:-<empty>}'"

printf 'host-fact-probes: OK\n'
