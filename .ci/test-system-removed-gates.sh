#!/usr/bin/env bash
# Prove the fail-safe direction of a `removed:` manifest entry.
#
# An install gate that resolves false leaves a file uninstalled, which is
# recoverable. A REMOVAL gate that resolves false-when-unknown DELETES a live
# /etc file, which is not. The registry rule -- a fact whose value is unknown
# MUST skip rather than act -- therefore binds hardest here, and nothing proved
# it: /etc/sddm.conf.d/90-breeze.conf was gated on `!displayManagerSddm`, and
# that fact is false whenever the displayManager probe cannot answer, so an
# unreadable probe removed the greeter drop-in from a real SDDM host.
#
# The per-line fact cache filter is what makes the unknown case reachable on an
# ordinary desktop: one dropped `displayManager` line is enough, with `headless`
# still false, so `headless`'s inverted absentDefault does not mask it.
#
# This renders the REAL desktop and hardware installers against crafted caches
# and asserts the removal branch, not the fact value: the fact is an
# implementation detail, the file surviving is the contract.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/system-removed-gates.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'system-removed-gates: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'system-removed-gates: ok - %s\n' "$*"; }

command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is required on PATH'

desktop_installer='.chezmoiscripts/30-linux/run_onchange_after_install-system-10-desktop.sh.tmpl'
hardware_installer='.chezmoiscripts/30-linux/run_onchange_after_install-system-18-hardware.sh.tmpl'

mkdir -p "$scratch/source" "$scratch/target" "$scratch/cache/chezmoi" "$scratch/bin" "$scratch/home"
cp -a "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" "$repo_root/system" "$scratch/source/"
mkdir -p "$scratch/source/.chezmoiscripts/30-linux"
cp -a "$repo_root/$desktop_installer" "$scratch/source/$desktop_installer"
cp -a "$repo_root/$hardware_installer" "$scratch/source/$hardware_installer"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"

cache_file="$scratch/cache/chezmoi/facts.yaml"

# The hook fact cache facts.tmpl reads: FLAT, unindented lines, with string values
# quoted -- exactly what write_facts_cache emits and what facts.tmpl's per-line
# filter accepts. Only the lines a case needs are written; every other hook fact
# takes its declared absentDefault, which is what an ordinary host looks like when
# one probe could not answer.
write_cache() {
  {
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
  } >"$cache_file"
}

# Renders one installer and prints the shell the removal loop would run against.
render() {
  local installer=$1
  env HOME="$scratch/home" XDG_CACHE_HOME="$scratch/cache" PATH="$scratch/bin:$PATH" \
    chezmoi --config "$scratch/empty.toml" --source "$scratch/source" \
    --destination "$scratch/target" \
    --override-data '{"chezmoi":{"os":"linux","osRelease":{"id":"fedora"}}}' \
    execute-template <"$scratch/source/$installer" >"$scratch/rendered.sh" 2>"$scratch/render.err" || {
    printf 'render failed:\n' >&2
    sed 's/^/  /' "$scratch/render.err" >&2
    exit 1
  }
}

# The removal loop is data-driven through parallel arrays, so the gate this path
# actually takes is the REMOVED_GATES entry beside its REMOVED_PATHS entry. The
# hardware loop interleaves a REMOVED_DISTROS array; only the two named arrays
# are read, so the extra one is skipped.
removal_gate() {
  local drop_in=$1
  awk -v want="$drop_in" '
    /^REMOVED_PATHS\+=\(/ { gsub(/^REMOVED_PATHS\+=\("|"\)$/, ""); path = $0; next }
    /^REMOVED_GATES\+=\(/ { gsub(/^REMOVED_GATES\+=\("|"\)$/, ""); if (path == want) { print; exit } }
  ' "$scratch/rendered.sh"
}

# The install loop's gate for one managed file, from the rendered override arrays.
override_gate() {
  local rel=$1
  awk -v want="$rel" '
    /^override_patterns\+=\(/ { gsub(/^override_patterns\+=\("|"\)$/, ""); path = $0; next }
    /^override_gates\+=\(/ { gsub(/^override_gates\+=\("|"\)$/, ""); if (path == want) { print; exit } }
  ' "$scratch/rendered.sh"
}

# Runs the rendered removal loop against a destination seeded with one drop-in
# and reports whether that drop-in survived. The whole installer needs root, so
# only the removal loop is extracted -- it is the branch under test. The
# hardware loop also filters on the distro id, which is pinned to the fixture's.
removal_removes() {
  local drop_in=$1 content=$2
  local dest="$scratch/dest"
  rm -rf -- "$dest"
  mkdir -p "$dest$(dirname "$drop_in")"
  printf '%s\n' "$content" >"$dest$drop_in"
  {
    sed -n '/^  FACT_/p' "$scratch/rendered.sh"
    printf 'DEST=%q\nos_id=fedora\n' "$dest"
    awk '/^gate_ok\(\) \{$/, /^\}$/' "$scratch/rendered.sh"
    awk '/^fact_gate\(\) \{$/, /^\}$/' "$scratch/rendered.sh"
    awk '/^REMOVED_PATHS=\(\)$/, /^done$/' "$scratch/rendered.sh"
  } >"$scratch/removal.sh"
  # The loop removes an absolute path; redirect it into the scratch destination.
  sed -i 's|"\${SUDO\[@\]}" rm -f "$dst"|rm -f "${DEST}${dst}"|; s|\[\[ -e "$dst" \|\| -L "$dst" \]\]|[[ -e "${DEST}${dst}" \|\| -L "${DEST}${dst}" ]]|' \
    "$scratch/removal.sh"
  printf 'SUDO=()\n%s' "$(cat "$scratch/removal.sh")" >"$scratch/removal.run.sh"
  bash "$scratch/removal.run.sh" >/dev/null 2>&1 || fail 'the extracted removal loop did not run'
  [[ ! -e "$dest$drop_in" ]]
}

breeze_drop_in='/etc/sddm.conf.d/90-breeze.conf'
breeze_content=$'[Theme]\nCurrent=breeze'

# --- The gate is the positive fact, not the inverse of the install gate ------
write_cache 'displayManager: "sddm"'
render "$desktop_installer"
[[ "$(removal_gate "$breeze_drop_in")" == 'sddmBreezeRetirable' ]] ||
  fail "the greeter drop-in retirement is gated on $(removal_gate "$breeze_drop_in"), not on a positive known-host fact"
pass 'the retirement entry gates on sddmBreezeRetirable'

# --- Unknown display manager: remove NOTHING --------------------------------
# The defect this file exists to keep fixed. One dropped cache line, headless
# still false, and the old gate deleted a live SDDM host's drop-in.
write_cache 'headless: false'
render "$desktop_installer"
grep -qx '  FACT_SDDM_BREEZE_RETIRABLE=0' "$scratch/rendered.sh" ||
  fail 'an unresolved display manager did not resolve the retirement fact false'
if removal_removes "$breeze_drop_in" "$breeze_content"; then
  fail 'an unresolved display manager REMOVED the greeter drop-in; an unknown fact must skip, never act'
fi
pass 'an unresolved display manager removes nothing'

# --- Known SDDM host with the theme: KEEP ------------------------------------
# sddmBreeze is a template fact probing a path this runner does not have, so the
# usable case is asserted through the rendered fact rather than by faking /usr.
write_cache 'displayManager: "sddm"'
render "$desktop_installer"
grep -qx '  FACT_DISPLAY_MANAGER_SDDM=1' "$scratch/rendered.sh" ||
  fail 'a declared sddm display manager did not resolve displayManagerSddm true'
pass 'a known SDDM host resolves the boolean companion true'

# --- Known non-SDDM host: RETIRE ---------------------------------------------
write_cache 'displayManager: "plasmalogin"'
render "$desktop_installer"
grep -qx '  FACT_SDDM_BREEZE_RETIRABLE=1' "$scratch/rendered.sh" ||
  fail 'a known non-SDDM host did not resolve the retirement fact true'
removal_removes "$breeze_drop_in" "$breeze_content" ||
  fail 'a known non-SDDM host did not retire the greeter drop-in'
pass 'a known non-SDDM host retires the drop-in'

# --- Known SDDM host that lost the theme: RETIRE -----------------------------
# The second half of the fix. Under !displayManagerSddm this host neither
# installed the drop-in nor retired it, so it kept a Current=breeze file pointing
# at a theme that is gone -- the broken login screen the sddmBreeze guard exists
# to prevent, reached through the retirement path instead.
#
# sddmBreeze probes an absolute path, so it is false on this runner: a declared
# `displayManager: sddm` with no theme present IS that host.
write_cache 'displayManager: "sddm"'
render "$desktop_installer"
if grep -qx '  FACT_SDDM_BREEZE=1' "$scratch/rendered.sh"; then
  printf 'system-removed-gates: skip - this host carries the breeze SDDM theme, so the themeless case is not reachable here\n'
else
  grep -qx '  FACT_SDDM_BREEZE_USABLE=0' "$scratch/rendered.sh" ||
    fail 'an SDDM host without the breeze theme resolved the install gate true'
  grep -qx '  FACT_SDDM_BREEZE_RETIRABLE=1' "$scratch/rendered.sh" ||
    fail 'an SDDM host that lost the breeze theme did not retire the drop-in it can no longer use'
  removal_removes "$breeze_drop_in" "$breeze_content" ||
    fail 'an SDDM host that lost the breeze theme kept a Current=breeze file pointing at a missing theme'
  pass 'an SDDM host that lost the theme retires the drop-in'
fi

# --- No display manager at all -----------------------------------------------
# An empty string is not a known host: the probe answered, but there is nothing
# to be a greeter. Removing a file that was never installed would be a no-op, and
# not removing it is the same no-op with the fail-safe direction.
write_cache 'displayManager: ""'
render "$desktop_installer"
grep -qx '  FACT_SDDM_BREEZE_RETIRABLE=0' "$scratch/rendered.sh" ||
  fail 'a host with no display manager resolved the retirement fact true'
pass 'a host with no display manager removes nothing'

# ============================================================================
# Hardware installer: the hybrid modprobe drop-ins retire on an integrated-only
# host. integratedOnly is a template fact derived from the gpuDeviceId and
# hybridGraphics hook facts, so one dropped hybridGraphics line is the unknown
# case here, exactly as a dropped displayManager line is above.
hybrid_power='/etc/modprobe.d/nvidia-hybrid-power.conf'
hybrid_modeset='/etc/modprobe.d/nvidia-hybrid-modeset.conf'
hybrid_content='options nvidia NVreg_DynamicPowerManagement=0x02'

# --- Pascal hybrid host: RETIRE both drop-ins --------------------------------
write_cache 'gpuDeviceId: "1d34"' 'hybridGraphics: true'
render "$hardware_installer"
[[ "$(removal_gate "$hybrid_power")" == 'integratedOnly' ]] ||
  fail "the hybrid power drop-in retirement is gated on $(removal_gate "$hybrid_power"), not on integratedOnly"
[[ "$(removal_gate "$hybrid_modeset")" == 'integratedOnly' ]] ||
  fail "the hybrid modeset drop-in retirement is gated on $(removal_gate "$hybrid_modeset"), not on integratedOnly"
removal_removes "$hybrid_power" "$hybrid_content" ||
  fail 'a Pascal hybrid host did not retire the hybrid power drop-in'
removal_removes "$hybrid_modeset" "$hybrid_content" ||
  fail 'a Pascal hybrid host did not retire the hybrid modeset drop-in'
pass 'a Pascal hybrid host retires both hybrid drop-ins'

# --- Pascal GPU, hybridGraphics unknown: remove NOTHING ----------------------
write_cache 'gpuDeviceId: "1d34"'
render "$hardware_installer"
if removal_removes "$hybrid_power" "$hybrid_content"; then
  fail 'an unresolved hybridGraphics fact REMOVED the hybrid power drop-in; an unknown fact must skip, never act'
fi
if removal_removes "$hybrid_modeset" "$hybrid_content"; then
  fail 'an unresolved hybridGraphics fact REMOVED the hybrid modeset drop-in; an unknown fact must skip, never act'
fi
pass 'an unresolved hybridGraphics fact removes nothing'

# --- Ampere hybrid host: KEEP the driver and its drop-ins --------------------
write_cache 'gpuDeviceId: "2487"' 'hybridGraphics: true'
render "$hardware_installer"
if removal_removes "$hybrid_power" "$hybrid_content"; then
  fail 'an Ampere hybrid host REMOVED the hybrid power drop-in'
fi
if removal_removes "$hybrid_modeset" "$hybrid_content"; then
  fail 'an Ampere hybrid host REMOVED the hybrid modeset drop-in'
fi
grep -qx '  FACT_NVIDIA_HYBRID_DRIVER=1' "$scratch/rendered.sh" ||
  fail 'an Ampere hybrid host did not resolve nvidiaHybridDriver true'
[[ "$(override_gate 'etc/modprobe.d/nvidia-hybrid-power.conf')" == 'nvidiaHybridDriver' ]] ||
  fail "the hybrid power drop-in installs on $(override_gate 'etc/modprobe.d/nvidia-hybrid-power.conf'), not on nvidiaHybridDriver"
[[ "$(override_gate 'etc/modprobe.d/nvidia-hybrid-modeset.conf')" == 'nvidiaHybridDriver' ]] ||
  fail "the hybrid modeset drop-in installs on $(override_gate 'etc/modprobe.d/nvidia-hybrid-modeset.conf'), not on nvidiaHybridDriver"
pass 'an Ampere hybrid host keeps both hybrid drop-ins and installs them'

printf 'system-removed-gates: all removal-gate assertions passed\n'
