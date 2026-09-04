#!/usr/bin/env bash
#
# chezmoi `read-source-state.pre` hook — installs the tooling chezmoi needs
# *before* it reads the source state:
#
#   * 1Password + 1Password CLI (`op`) — secret templates call `onepasswordRead`,
#     which requires an authenticated `op`.
#   * mise — the runtime / CLI version manager the rest of this config relies on.
#
# chezmoi runs a hook `command` verbatim and never renders it as a template, so
# this file MUST NOT be a `.tmpl`. OS divergence is decided at runtime by reading
# /etc/os-release on Linux, not from Go-template branches.

set -euo pipefail

# Prepend ~/.local/bin and ~/.local/sbin to PATH so non-login / non-interactive
# environments resolve user-installed and chezmoi-managed local binaries.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac
case ":$PATH:" in
  *":$HOME/.local/sbin:"*) ;;
  *) PATH="$HOME/.local/sbin:$PATH" ;;
esac
export PATH

# Container / CI detection: Podman creates /run/.containerenv, Docker creates
# /.dockerenv. Neither exists on a bare-metal host or VM.
#
# distrobox and toolbox are the OPT-OUT: both bind-mount the host $HOME and both
# create /run/.toolboxenv (distrobox touches it for toolbx compatibility), so an
# apply inside one targets the real host $HOME and must provision like the host.
# Treat only a "real" container — a marker WITHOUT /run/.toolboxenv — as one here.
is_devbox() {
  [[ -f /run/.toolboxenv ]]
}

is_container() {
  [[ -f /run/.containerenv || -f /.dockerenv ]] || return 1
  ! is_devbox
}

# `op vault list` is 1Password's documented desktop-app integration probe and
# also works with OP_SERVICE_ACCOUNT_TOKEN. Unlike `op whoami`, it does not
# require a separately configured CLI account. Discard all output because vault
# metadata is not part of the bootstrap log. Exact secret authorization remains
# the later `onepasswordRead` calls' responsibility.
op_ready() {
  command -v op >/dev/null 2>&1 || return 1
  op vault list >/dev/null 2>&1
}

# Human-facing instructions for enabling the 1Password CLI. Printed once before
# waiting and again on timeout.
#
# The desktop-app integration cannot be the bootstrap path on every host. The
# vendor ships no arm64 desktop package, so on a Jetson the app arrives from the
# release-locked tarball in a LATER chezmoi phase — one that cannot run until
# this hook has already resolved secrets. Leading with "open the app" there would
# name a step the operator cannot take, so a host without the app installed is
# told to use a service-account token instead.
print_op_auth_guidance() {
  printf 'install-prerequisites.sh: 1Password CLI is not authenticated yet.\n' >&2
  if [[ -x /opt/1Password/1password ]] || command -v 1password >/dev/null 2>&1; then
    printf 'Let chezmoi resolve secrets by enabling the 1Password CLI:\n' >&2
    printf '  1. Open the 1Password desktop app and sign in.\n' >&2
    printf '  2. Enable Settings -> Developer -> Integrate with 1Password CLI.\n' >&2
    printf '  (Headless host? Export a service-account token instead and re-run:\n' >&2
    printf '     export OP_SERVICE_ACCOUNT_TOKEN=...   # op service account create --help)\n' >&2
    return 0
  fi
  printf 'The 1Password desktop app is not installed on this host, so the CLI has no\n' >&2
  printf 'app to integrate with. This repository installs it in a later phase, which\n' >&2
  printf 'runs after this one, so authenticate with a service account and re-run:\n' >&2
  printf '  export OP_SERVICE_ACCOUNT_TOKEN=...   # op service account create --help\n' >&2
  printf '(Once the desktop app is installed, Settings -> Developer -> Integrate with\n' >&2
  printf ' 1Password CLI is the normal path and no token is needed.)\n' >&2
}

# Poll op_ready() until it succeeds or a bounded deadline elapses. Interval and
# max-wait are env-overridable so the unit test can drive it fast with a stubbed
# `op` and a no-op `sleep`.
wait_for_op_auth() {
  local interval="${OP_AUTH_POLL_INTERVAL_SECS:-5}"
  local max_wait="${OP_AUTH_MAX_WAIT_SECS:-900}"
  local waited=0
  while ! op_ready; do
    if (( waited >= max_wait )); then
      printf 'install-prerequisites.sh: timed out after %ss waiting for 1Password CLI auth.\n' "$max_wait" >&2
      print_op_auth_guidance
      return 1
    fi
    sleep "$interval"
    waited=$(( waited + interval ))
    if (( waited % 30 == 0 )); then
      printf '  .. still waiting for 1Password CLI sign-in (%ss elapsed)\n' "$waited" >&2
    fi
  done
  return 0
}

# Return 0 once `op` can resolve secrets. Already authed -> return immediately.
# Otherwise guide the user; fail fast (like the container branch) when stdin is
# not a TTY so a headless/CI run never hangs; else wait interactively.
ensure_op_authenticated() {
  if op_ready; then
    return 0
  fi
  print_op_auth_guidance
  # `[[ -t 0 ]]` is true only under an interactive chezmoi run; never block a
  # non-interactive / piped invocation waiting for a sign-in that cannot happen.
  if [[ ! -t 0 ]]; then
    printf 'install-prerequisites.sh: non-interactive shell; cannot wait for sign-in.\n' >&2
    return 1
  fi
  if wait_for_op_auth; then
    printf 'install-prerequisites.sh: 1Password CLI authenticated; continuing.\n' >&2
    return 0
  fi
  return 1
}

# config-secrets key: the chezmoi config template (.chezmoi.toml.tmpl) stores
# its prompted secrets (LUKS passphrase) AES-encrypted in
# ~/.config/chezmoi/chezmoi.toml instead of plaintext. The AES key lives ONLY
# in the user keyring (Secret Service) under service=chezmoi-config-secrets /
# user=<username>.
#
# This hook is an EARLY BEST-EFFORT seed, NOT the thing the first-init prompt
# depends on: chezmoi renders (and prompts on) the config template BEFORE it
# runs this read-source-state.pre hook, so on a fresh machine's first `chezmoi
# init` the key does not exist yet when the LUKS prompt fires. The prompt
# path in .chezmoi.toml.tmpl therefore resolves the key GET-OR-CREATE via
# .chezmoitemplates/config-secrets-key-ensure.tmpl, seeding it inside that same
# render. Seeding it here too keeps it present for later commands.
# Idempotent: after the first render created the key, this GET finds it and
# no-ops. NEVER fail (or hang) the hook over it: with no reachable keyring
# (headless/TTY/container) the templates behave as if no secret was entered.
#
# LINUX-ONLY, deliberately: the encrypted config secret is Linux-gated, and
# macOS's keyring backend (go-keyring drives /usr/bin/security) can escalate
# to a BLOCKING SecurityAgent dialog on a locked keychain — which wedges a
# headless apply forever (observed hanging the render-dotfiles macos CI job).
# Revisit the guard if a darwin template ever consumes the key. The `timeout`
# wrappers are the same insurance on Linux (coreutils is a base package on
# the target distro): a Secret Service prompter that never answers turns
# into a soft-skip, not a stuck chezmoi run.
ensure_config_secrets_key() {
  [[ "$(uname -s)" == "Linux" ]] || return 0
  command -v chezmoi >/dev/null 2>&1 || return 0
  local user existing key
  user="${USER:-$(id -un)}"
  existing="$(timeout 10 chezmoi secret keyring get --service=chezmoi-config-secrets --user="$user" 2>/dev/null || true)"
  [[ -n "$existing" ]] && return 0
  key="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  if ! timeout 10 chezmoi secret keyring set --service=chezmoi-config-secrets --user="$user" --value="$key" 2>/dev/null; then
    printf 'install-prerequisites.sh: user keyring unreachable; config-template secrets cannot be stored this run.\n' >&2
  fi
  return 0
}

# --- Host-fact cache — layer 1 of the named-fact registry -------------------
#
# The registry's SHELL layer (names declared in .chezmoidata/facts.yaml; merged
# entry point .chezmoitemplates/facts.tmpl). These four facts live here — and not
# in a template — because the template functions cannot express them:
#
#   * `output` propagates a non-zero exit as a template error that ABORTS the
#     render. `systemd-detect-virt --vm` exits 1 on a bare-metal host, so a
#     template-side probe would hard-fail every chezmoi command on this machine.
#   * `glob` does not traverse symlinks, and /sys/bus/pci/devices/* is nothing
#     BUT symlinks — a template-side PCI walk misses a GPU behind a PCIe bridge
#     and reports nvidia=false on a host that has one (this host).
#
# chezmoi runs this file as its `read-source-state.pre` hook, i.e. ONCE per
# chezmoi command and BEFORE the source state is read, so the cache written here
# is fresh for the render that immediately follows. facts.tmpl reads it back with
# a stat-guarded absolute-path `include` (which works even under the empty
# --config of the AGENTS.md stub-`op` recipe and the CI render-internals job,
# where this hook does not run at all — the file simply persists from the last
# real command) and merges it with the in-process probes (DMI reads, `stat`,
# `lookPath`) into the one fact map every consumer imports.
#
# Three rules govern this block:
#
#   1. Every probe ALWAYS exits 0 and prints a bare `true` / `false`. A host
#      that lacks the probe's mechanism (no systemd-detect-virt, no /sys, no
#      dpkg — macOS, a minimal container) prints `false`, which is the
#      conservative direction for all four: skip NVIDIA, skip the
#      bare-metal package set, skip ThinkPad ACPI, treat the host as a desktop
#      rather than a server.
#   2. It NEVER fails the hook. A read-only or full $HOME must not take down
#      `chezmoi diff`; a warning plus a missing cache degrades to exactly the
#      all-false that facts.tmpl already renders when the file is absent.
#   3. It runs on EVERY host — containers included, and BEFORE the mise/op fast
#      path below, for the same reason ensure_config_secrets_key does: a fully
#      provisioned host short-circuits there, and it still has to refresh its
#      facts on every command.
#
# `set -e` safety: each fact_* helper is called from a command substitution and
# always returns 0 (the printf is the last command), so nothing here can abort
# the hook.

# Print `true` if the command succeeds, `false` otherwise. Wraps every probe so
# a failing/absent mechanism is a value, never an error.
fact_bool() {
  if "$@" >/dev/null 2>&1; then printf 'true'; else printf 'false'; fi
}

# A STRING-valued fact. The probe prints its value on stdout; anything outside the
# charset facts-sh.tmpl allows through to an unquoted shell assignment is dropped
# to the empty string, which is the skip value every string fact declares. A probe
# that fails, prints nothing, or prints a value with a space, a newline, or a shell
# metacharacter therefore skips what it gates instead of leaking an unquotable
# token into every consumer.
#
# THE VALUE IS ALWAYS QUOTED. An all-digit id such as a PCI device `2704` parses
# out of YAML as a NUMBER when written bare, the reader's string type check then
# rejects it, and the fact silently takes its empty default -- losing exactly the
# identity the installer needs in order to name what it skipped. Quoting makes
# every string fact round-trip as a string, and makes the empty value the same
# shape as any other.
fact_string() {
  local value=''
  value="$("$@" 2>/dev/null)" || value=''
  if [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf '"%s"' "$value"
  else
    printf '""'
  fi
}

# NVIDIA GPU: PCI vendor id 0x10de anywhere on the bus. Verbatim the probe both
# package installers already run — sysfs, not lspci, because pciutils is not
# guaranteed installed this early and the vendor files always exist. A missing
# /sys (macOS) leaves the glob unexpanded; grep then fails on a nonexistent path
# and the fact is false.
# ONE pass over the PCI bus, three facts. This runs in chezmoi's
# read-source-state.pre hook, once per `chezmoi diff`/`apply`/`status`/
# `execute-template` -- so three independent globs of /sys/bus/pci/devices/*,
# each re-reading `vendor` and `class` for every device on the bus, was work paid
# interactively on every invocation of the tool.
#
# Class-filtered to 0x03* (display controllers) for the GPU identity and the
# hybrid check, so an NVIDIA audio function or USB-C controller on the same card
# is not mistaken for the GPU. The vendor-presence fact deliberately stays
# unfiltered: it answers "is there an NVIDIA device on this bus at all", which is
# what gates whether the installer is deployed.
PCI_SCAN_DONE=0
PCI_NVIDIA_PRESENT=0
PCI_NVIDIA_DISPLAY_ID=""
PCI_OTHER_DISPLAY=0

scan_pci_bus() {
  [[ "$PCI_SCAN_DONE" -eq 1 ]] && return 0
  PCI_SCAN_DONE=1
  local dev vendor class id
  for dev in /sys/bus/pci/devices/*/; do
    [[ -r "$dev/vendor" ]] || continue
    read -r vendor <"$dev/vendor" 2>/dev/null || continue
    [[ "$vendor" == '0x10de' ]] && PCI_NVIDIA_PRESENT=1
    [[ -r "$dev/class" ]] || continue
    read -r class <"$dev/class" 2>/dev/null || continue
    [[ "$class" == 0x03* ]] || continue
    if [[ "$vendor" == '0x10de' ]]; then
      if [[ -z "$PCI_NVIDIA_DISPLAY_ID" && -r "$dev/device" ]]; then
        read -r id <"$dev/device" 2>/dev/null && PCI_NVIDIA_DISPLAY_ID="${id#0x}"
      fi
    else
      PCI_OTHER_DISPLAY=1
    fi
  done
  return 0
}

# An NVIDIA device anywhere on the PCI bus, including behind a bridge. This is
# what decides whether the driver installer is deployed at all.
fact_nvidia() {
  scan_pci_bus
  [[ "$PCI_NVIDIA_PRESENT" -eq 1 ]]
}

# The PCI device id of the host's NVIDIA DISPLAY device, four hex digits with no
# 0x prefix (a Quadro P520 prints `1d34`). Raw hardware identity and nothing else:
# the mapping from an id to an architecture, and from an architecture to a driver
# branch, is data in .chezmoidata/nvidia.yaml.
fact_gpu_device_id() {
  scan_pci_bus
  [[ -n "$PCI_NVIDIA_DISPLAY_ID" ]] || return 1
  printf '%s' "$PCI_NVIDIA_DISPLAY_ID"
}

# Hybrid graphics: an NVIDIA display device AND a display device from another
# vendor, which is what an Optimus-style laptop looks like. A desktop with one
# discrete card is NOT hybrid and must not receive render-offload or runtime
# power-management options.
fact_hybrid_graphics() {
  scan_pci_bus
  [[ -n "$PCI_NVIDIA_DISPLAY_ID" && "$PCI_OTHER_DISPLAY" -eq 1 ]]
}

# A SYSTEM battery, not a peripheral one. A wireless mouse or keyboard registers
# an ordinary power supply too, and this fleet already runs a mouse-battery
# watcher on desktops -- so `type == Battery` alone would make every such desktop
# claim laptop power behaviour. The kernel distinguishes them with `scope`:
# `Device` for a peripheral, `System` (or absent, on a chassis battery whose
# driver predates the attribute) for the machine's own.
fact_battery() {
  local supply type scope
  for supply in /sys/class/power_supply/*/; do
    [[ -r "$supply/type" ]] || continue
    read -r type <"$supply/type" 2>/dev/null || continue
    [[ "$type" == 'Battery' ]] || continue
    scope='System'
    [[ -r "$supply/scope" ]] && { read -r scope <"$supply/scope" 2>/dev/null || scope='System'; }
    [[ "$scope" == 'Device' ]] || return 0
  done
  return 1
}

# A fingerprint reader this repository knows how to manage. There is NO generic
# sysfs signal for one: the readers present a vendor-specific USB interface class
# and expose no product string, so the identity has to be declared. The list lives
# in .chezmoidata/.fingerprint-readers.tsv -- dot-prefixed and TSV for the same
# reason .chezmoidata/.capability-registry.tsv is, so it stays out of the template
# data map and stays readable from this hook, which runs before the source state
# and has no YAML parser.
#
# Seeded, not exhaustive. An unlisted reader resolves false and the fingerprint
# path skips, which is the fail-safe direction: no authentication factor is
# enabled for hardware nobody verified.
fact_fingerprint_reader() {
  local table dev vendor product known=''
  table="${CHEZMOI_SOURCE_DIR:-$(dirname -- "${BASH_SOURCE[0]}")}/.chezmoidata/.fingerprint-readers.tsv"
  [[ -r "$table" ]] || return 1
  # Read the table ONCE. A host has tens of USB entries -- hubs, interfaces and
  # endpoints included -- and this runs in the pre-hook on every chezmoi command,
  # so forking a grep per entry against a two-line file was the wrong shape.
  known="$(< "$table")" || return 1
  for dev in /sys/bus/usb/devices/*/; do
    [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]] || continue
    read -r vendor <"$dev/idVendor" 2>/dev/null || continue
    read -r product <"$dev/idProduct" 2>/dev/null || continue
    case $'\n'"$known"$'\n' in
      *$'\n'"$vendor"$'\t'"$product"$'\n'*) return 0 ;;
    esac
  done
  return 1
}

# Which display manager the host runs, as the bare unit name (`plasmalogin`,
# `gdm`, `sddm`). Read from the display-manager.service alias symlink systemd
# creates when a DM is enabled -- the same signal `headless` already trusts as a
# reliable positive. Hook-probed because resolving a symlink target is not
# something the template layer can do.
fact_display_manager() {
  local target
  # The alias must EXIST before it is resolved. `readlink -f` succeeds on a
  # missing path and prints the path back, so without this guard a host with no
  # display manager resolves the fact to the literal string "display-manager"
  # instead of the empty absentDefault the registry declares -- a fabricated
  # value where the contract promises "unknown". fact_headless guards the same
  # symlink the same way.
  [[ -L /etc/systemd/system/display-manager.service ]] || return 1
  target="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" || return 1
  [[ -n "$target" ]] || return 1
  target="${target##*/}"
  printf '%s' "${target%.service}"
}

# Headless / server install. Mirrors .chezmoitemplates/headless-guard.sh.tmpl
# EXACTLY (keep the two in lockstep): a host is headless when its systemd default
# target is not graphical.target AND no display-manager alias symlink exists.
# A host without systemd falls through as NOT headless — the same direction the
# guard takes when `systemctl` is missing (it runs the script).
fact_headless() {
  command -v systemctl >/dev/null 2>&1 || return 1
  local default_target
  default_target="$(systemctl get-default 2>/dev/null || true)"
  [[ "$default_target" != "graphical.target" && ! -L /etc/systemd/system/display-manager.service ]]
}

# vm and virt are TWO facts on purpose — the repo already treats them as two
# conditions and collapsing them would flip a consumer:
#   vm   = `systemd-detect-virt --vm`  (VMs only) — system.yaml's `vm` gate, the
#          one fact gating a PRIVILEGE GRANT (etc/sudoers.d/*, %wheel NOPASSWD).
#   virt = bare `systemd-detect-virt`  (containers too) — both installers'
#          IS_VIRT, which gates bareMetalPackages.
# One fact would either install bare-metal packages inside a distrobox or drop a
# password-less sudo file where it does not land today.
# A cache we could not refresh must not be read. Every early-return below used to
# leave the PREVIOUS cache in place while warning that facts "will render false"
# — so a host whose cache went unwritable silently kept resolving LAST BOOT's
# hardware identity, and the fail-safe defaults in facts.tmpl never engaged. Two
# reviewers found the same hole independently. Delete it instead; if even that
# fails, say so honestly rather than promising a fallback that will not happen.
invalidate_facts_cache() {
  local cache_file="$1"
  [[ -e "$cache_file" ]] || {
    printf 'install-prerequisites.sh: cannot write %s; host facts take their fail-safe defaults this run.\n' "$cache_file" >&2
    return 0
  }
  if rm -f "$cache_file" 2>/dev/null; then
    printf 'install-prerequisites.sh: cannot refresh %s; removed it, so host facts take their fail-safe defaults this run.\n' "$cache_file" >&2
  else
    printf 'install-prerequisites.sh: cannot refresh OR remove %s; host facts may be STALE this run.\n' "$cache_file" >&2
  fi
}

write_facts_cache() {
  local cache_dir cache_file tmp_file
  cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/chezmoi"
  cache_file="$cache_dir/facts.yaml"

  mkdir -p "$cache_dir" 2>/dev/null || {
    invalidate_facts_cache "$cache_file"
    return 0
  }

  tmp_file="$(mktemp "$cache_file.XXXXXX" 2>/dev/null)" || {
    invalidate_facts_cache "$cache_file"
    return 0
  }

  # Walk the PCI bus HERE, in this shell. Each fact below is evaluated inside a
  # command substitution, and a subshell cannot write PCI_SCAN_DONE back to its
  # parent -- so memoizing inside the first fact would leave the next two walking
  # the bus again. Scanning first inverts that: the subshells INHERIT the
  # finished scan and return from the memo, which is what makes the single pass
  # real. The facts stay ordinary probes, correct whether or not this ran.
  scan_pci_bus

  {
    printf '# Generated by .install-prerequisites.sh (chezmoi read-source-state.pre hook).\n'
    printf '# Rewritten once per chezmoi command; read by .chezmoitemplates/facts.tmpl.\n'
    printf '# Do NOT edit — every value here is a probe result, not a setting.\n'
    printf 'headless: %s\n'     "$(fact_bool fact_headless)"
    printf 'nvidia: %s\n'       "$(fact_bool fact_nvidia)"
    printf 'gpuDeviceId: %s\n'  "$(fact_string fact_gpu_device_id)"
    printf 'hybridGraphics: %s\n' "$(fact_bool fact_hybrid_graphics)"
    printf 'battery: %s\n'      "$(fact_bool fact_battery)"
    printf 'fingerprintReader: %s\n' "$(fact_bool fact_fingerprint_reader)"
    printf 'displayManager: %s\n' "$(fact_string fact_display_manager)"
    printf 'virt: %s\n'         "$(fact_bool systemd-detect-virt --quiet)"
    printf 'vm: %s\n'           "$(fact_bool systemd-detect-virt --vm --quiet)"
  } >"$tmp_file" || {
    # THE WRITE NEEDS THE SAME GUARD AS ITS NEIGHBOURS. This file runs under
    # `set -euo pipefail` AS CHEZMOI'S read-source-state.pre HOOK, so an
    # unguarded write error — a full disk, an exceeded quota, EIO — trips
    # errexit, the hook exits non-zero, and EVERY chezmoi command aborts:
    # diff, apply, execute-template, the lot. A cache the user cannot write
    # must degrade to no cache, never to a bricked dotfiles tool.
    rm -f "$tmp_file" 2>/dev/null || true
    invalidate_facts_cache "$cache_file"
    return 0
  }

  # VALIDATE OUR OWN OUTPUT BEFORE PUBLISHING IT. facts.tmpl parses this file per
  # line and silently drops a line it cannot read, which is the right blast radius
  # for a truncated or hand-edited cache but would hide a defect in this writer.
  # So the writer checks the lines it just built: a malformed one is dropped here,
  # loudly, naming the fact whose value the render will now take from its declared
  # default. The accepted shapes match the reader's filter exactly.
  local bad_facts=()
  local line
  while IFS= read -r line; do
    [[ "$line" == '#'* || -z "$line" ]] && continue
    [[ "$line" =~ ^[A-Za-z][A-Za-z0-9]*:\ (true|false|\"[A-Za-z0-9._-]*\")$ ]] && continue
    bad_facts+=("${line%%:*}")
  done <"$tmp_file"
  if ((${#bad_facts[@]} > 0)); then
    printf 'install-prerequisites.sh: dropped %d malformed fact line(s) from the cache: %s\n' \
      "${#bad_facts[@]}" "${bad_facts[*]}" >&2
    printf 'install-prerequisites.sh: those facts take their declared fail-safe defaults this run; this is a defect in write_facts_cache, not in the host.\n' >&2
    grep -vxE '[A-Za-z][A-Za-z0-9]*: (true|false|"[A-Za-z0-9._-]*")' "$tmp_file" >/dev/null 2>&1 && {
      local kept_file
      kept_file="$(mktemp "$cache_file.XXXXXX" 2>/dev/null)" || kept_file=''
      if [[ -n "$kept_file" ]]; then
        grep -xE '(#.*|[A-Za-z][A-Za-z0-9]*: (true|false|"[A-Za-z0-9._-]*"))' "$tmp_file" >"$kept_file" 2>/dev/null || true
        mv -f "$kept_file" "$tmp_file" 2>/dev/null || rm -f "$kept_file" 2>/dev/null || true
      fi
    }
  fi

  # Atomic swap: a template mid-render must never see a half-written cache.
  mv -f "$tmp_file" "$cache_file" 2>/dev/null || {
    rm -f "$tmp_file"
    invalidate_facts_cache "$cache_file"
  }
  return 0
}

# The source-state read no longer calls the GitHub API: every tool version,
# URL, and digest is pinned by the release lock (.chezmoidata/releases.json),
# so templates render with zero network I/O. Apply-time downloads (external
# repos and release assets such as fonts and mise-managed tools) still hit
# GitHub, and a token lifts the anonymous 60-requests/hour-per-IP limit should
# anything reach the API — useful, but it must no longer abort the bootstrap.
# chezmoi authenticates with the first of these it finds:
# CHEZMOI_GITHUB_ACCESS_TOKEN, then GITHUB_ACCESS_TOKEN, then GITHUB_TOKEN.
ensure_github_token() {
  if [[ -n "${CHEZMOI_GITHUB_ACCESS_TOKEN:-}" \
     || -n "${GITHUB_ACCESS_TOKEN:-}" \
     || -n "${GITHUB_TOKEN:-}" ]]; then
    return 0
  fi
  printf 'install-prerequisites.sh: no GitHub API token in the environment.\n' >&2
  printf 'Renders no longer call the GitHub API (the release lock pins every tool),\n' >&2
  printf 'so this is advisory only: apply-time downloads still benefit from a token.\n' >&2
  printf 'To set one, inject the PAT from 1Password and re-run in the same shell:\n' >&2
  # SC2016: the $(op read ...) is literal text for the user to copy, not for us to expand.
  # shellcheck disable=SC2016
  printf '  export GITHUB_TOKEN=$(op read "op://Private/GitHub/PAT")\n' >&2
  return 0
}

# --- Capability cache — one probe snapshot per chezmoi command ---------------
#
# Momentary host state (a live session bus, a cached sudo credential, whether a
# tool this repo installs is on PATH yet) that transient-blocking skip sites hash
# through fingerprint.tmpl so they re-run once the precondition appears. Read by
# .chezmoitemplates/capabilities.tmpl, which performs NO probe of its own.
#
# WHY IT LIVES HERE AND NOT IN A TEMPLATE. The converted tree names ~34 distinct
# probes across ~57 blocking sites. Probing per include ran one subprocess per
# CALL on every chezmoi command — `status` and `diff` included — and made two
# renders inside one command disagree. Resolving every registry entry once here
# is one snapshot per command, and it is taken BEFORE the source state is read.
#
# WHY IT IS NOT THE FACT REGISTRY. facts.yaml excludes momentary state from host
# identity and gates on facts; a capability never appears in a `gates:`
# expression and is only ever a fingerprint input, so it cannot fail open. Do not
# merge the two.
#
# FAIL-CLOSED, UNLIKE write_facts_cache. A fact cache that cannot be refreshed
# degrades to declared per-fact fail-safe defaults, so it warns and continues.
# A capability record cannot do that: a leftover record from an EARLIER command
# still looks structurally valid to the reader, and publishing last command's
# `available` would let a blocking site claim convergence it never reached. Every
# removal, permission, creation, write, rename or validation fault therefore
# deletes this identity's own record when it safely can and exits non-zero, which
# stops the command before a single template renders.
#
# The four `any` command probes are resolved by this hook on supported POSIX
# hosts; Linux-only probes never launch off Linux.
CAPABILITY_CACHE_SCHEMA='capability-cache-v1'
CAPABILITY_REGISTRY_SCHEMA='capability-registry-v2'
# Hidden basename on purpose: chezmoi discovers .chezmoidata/ recursively and
# aborts EVERY command with ".tsv: unknown format" on a visible unknown-format
# data file (verified on v2.71.0), while it skips dot-prefixed entries. The
# registry is deliberately not chezmoi data — it must never merge into the
# template data map — so the dot is what keeps it beside the data it belongs
# with. Keep this path byte-identical to capabilities.tmpl's.
CAPABILITY_REGISTRY_RELPATH='.chezmoidata/.capability-registry.tsv'
CAPABILITY_REGISTRY_KINDS=(
  absolute-executable absolute-file command-present graphical-session
  session-bus sudo-nonrefreshing unix-socket user-manager-bus user-manager-unit
  user-process
)
CAPABILITY_REGISTRY_PLATFORMS=(any linux)
CAPABILITY_REGISTRY_SIDE_EFFECTS=(none read-only-subprocess sudo-credential-probe)

capability_cache_fail() {
  printf 'install-prerequisites.sh: capability cache: %s\n' "$*" >&2
  printf 'install-prerequisites.sh: refusing to render with a capability record this command did not publish.\n' >&2
  exit 1
}

capability_has() {
  local needle=$1 candidate
  shift
  for candidate in "$@"; do
    [[ "$candidate" != "$needle" ]] || return 0
  done
  return 1
}

# Parse and validate the versioned registry into its key, kind, and platform
# arrays, and record the SHA-256 of its EXACT bytes. Shape violations are refused
# rather than skipped: the registry is checked-in source, the reader recomputes
# the same digest over the same bytes, and a row this hook cannot map to reviewed
# code has no safe reading. Digests through capability_cache_identity_sha256, so
# the caller must already have sourced .chezmoitemplates/capability-cache-identity.sh.
read_capability_registry() {
  local LC_ALL=C path=$1 line_no=0 previous='' key kind side platform available unavailable rest
  CAPABILITY_KEYS=()
  CAPABILITY_KINDS=()
  CAPABILITY_PLATFORMS=()
  [[ -f "$path" && ! -L "$path" ]] || capability_cache_fail "registry $path is missing or not a regular file"
  CAPABILITY_REGISTRY_DIGEST=$(capability_cache_identity_sha256 <"$path")
  [[ -n "$CAPABILITY_REGISTRY_DIGEST" ]] || capability_cache_fail 'no sha256sum/shasum available to digest the registry'
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    if ((line_no == 1)); then
      [[ "$line" == "$CAPABILITY_REGISTRY_SCHEMA" ]] \
        || capability_cache_fail "registry $path must start with $CAPABILITY_REGISTRY_SCHEMA, got ${line@Q}"
      continue
    fi
    IFS=$'\t' read -r key kind side platform available unavailable rest <<<"$line"
    [[ -z "$rest" ]] || capability_cache_fail "registry line $line_no has more than six columns"
    [[ "$key" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || capability_cache_fail "registry line $line_no has invalid key ${key@Q}"
    [[ "$key" > "$previous" ]] || capability_cache_fail "registry line $line_no key $key is out of order or duplicated"
    capability_has "$kind" "${CAPABILITY_REGISTRY_KINDS[@]}" \
      || capability_cache_fail "registry key $key declares probe kind ${kind@Q}, which this hook has no reviewed code for"
    capability_has "$side" "${CAPABILITY_REGISTRY_SIDE_EFFECTS[@]}" \
      || capability_cache_fail "registry key $key declares side-effect class ${side@Q}"
    capability_has "$platform" "${CAPABILITY_REGISTRY_PLATFORMS[@]}" \
      || capability_cache_fail "registry key $key declares platform applicability ${platform@Q}"
    [[ "$available" == available && "$unavailable" == unavailable ]] \
      || capability_cache_fail "registry key $key must declare the fixed tokens available/unavailable"
    previous=$key
    CAPABILITY_KEYS+=("$key")
    CAPABILITY_KINDS+=("$kind")
    CAPABILITY_PLATFORMS+=("$platform")
  done <"$path"
  ((${#CAPABILITY_KEYS[@]} > 0)) || capability_cache_fail "registry $path declares no capability keys"
}

# The akonadi socket path the KDE consumers themselves resolve: the server's own
# rc file wins, the per-user runtime default is the fallback.
capability_akonadi_socket() {
  local rc="$HOME/.config/akonadi/akonadiserverrc" socket=''
  if [[ -f "$rc" ]]; then
    socket=$(grep -E '^Options=' "$rc" 2>/dev/null |
      sed -nE 's/.*UNIX_SOCKET=([^"]+).*/\1/p' | head -n1)
  fi
  [[ -n "$socket" ]] || socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/akonadi/mysql.socket"
  printf '%s' "$socket"
}

# The `timeout` utility is not portable to every supported POSIX host. Match the
# repository's bounded child-process convention so an unresponsive user manager
# returns an unavailable capability instead of wedging the chezmoi command.
capability_with_deadline() {
  local deadline_secs="${CAPABILITY_PROBE_DEADLINE_SECS:-5}"
  local term_grace_secs="${CAPABILITY_PROBE_TERM_GRACE_SECS:-2}"
  local probe_pid watchdog_pid probe_rc
  [[ "$deadline_secs" =~ ^[1-9][0-9]*$ && "$term_grace_secs" =~ ^[1-9][0-9]*$ ]] \
    || capability_cache_fail 'capability probe deadlines must be positive integer seconds'

  "$@" >/dev/null 2>&1 &
  probe_pid=$!
  (
    sleep_pid=
    trap '[ -z "$sleep_pid" ] || kill "$sleep_pid" 2>/dev/null || true; exit 0' HUP INT TERM
    sleep "$deadline_secs" &
    sleep_pid=$!
    wait "$sleep_pid" 2>/dev/null || exit 0
    if kill -0 "$probe_pid" 2>/dev/null; then
      kill -TERM "$probe_pid" 2>/dev/null || true
      sleep "$term_grace_secs" &
      sleep_pid=$!
      wait "$sleep_pid" 2>/dev/null || exit 0
      kill -KILL "$probe_pid" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!
  if wait "$probe_pid" 2>/dev/null; then
    probe_rc=0
  else
    probe_rc=$?
  fi
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  [[ "$probe_rc" -eq 0 ]]
}

# The registry supplies the key and the KIND; the code that runs is selected here
# and nowhere else. Registry text is never evaluated as shell, and a kind whose
# key this hook does not recognise is a hard failure rather than a guess.
resolve_capability() {
  local key=$1 kind=$2 name path
  case "$kind" in
    command-present)
      name=${key%-present}
      [[ "$name" != "$key" && "$name" =~ ^[a-z][a-z0-9+._-]*$ ]] \
        || capability_cache_fail "command-present key ${key@Q} does not name a command"
      command -v -- "$name" >/dev/null 2>&1
      ;;
    absolute-executable)
      case "$key" in
        usr-bin-python3-present) path=/usr/bin/python3 ;;
        usr-bin-1password-present) path=/usr/bin/1password ;;
        *) capability_cache_fail "absolute-executable key ${key@Q} has no reviewed path" ;;
      esac
      [[ -x "$path" ]]
      ;;
    absolute-file)
      # A file that only has to EXIST, not to be runnable. A signing certificate
      # a package's build system mints on its first build is the shape this
      # serves: it is the precondition a transient-blocking skip waits on, and
      # `-x` would never be true for it.
      case "$key" in
        akmods-signing-key-present) path=/etc/pki/akmods/certs/public_key.der ;;
        *) capability_cache_fail "absolute-file key ${key@Q} has no reviewed path" ;;
      esac
      [[ -f "$path" ]]
      ;;
    sudo-nonrefreshing)
      # `-N` is load-bearing: without it a successful probe REFRESHES the sudo
      # timestamp, and because this runs for `status` and `diff` too, read-only
      # commands would keep an expiring authorization alive indefinitely. The
      # timeout keeps a wedged sudo from stalling the command.
      if [[ "$(id -u)" == 0 ]]; then
        true
      else
        timeout 5 sudo -nN true >/dev/null 2>&1
      fi
      ;;
    session-bus)
      [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || [[ -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]]
      ;;
    graphical-session)
      [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]
      ;;
    user-process)
      name=${key%-running}
      [[ "$name" != "$key" && "$name" =~ ^[a-z][a-z0-9+._-]*$ ]] \
        || capability_cache_fail "user-process key ${key@Q} does not name a process"
      pgrep -xu "$(id -u)" -- "$name" >/dev/null 2>&1
      ;;
    unix-socket)
      case "$key" in
        akonadi-socket-present) [[ -S "$(capability_akonadi_socket)" ]] ;;
        *) capability_cache_fail "unix-socket key ${key@Q} has no reviewed socket" ;;
      esac
      ;;
    user-manager-bus)
      case "$key" in
        user-manager-bus-present) capability_with_deadline systemctl --user show-environment ;;
        *) capability_cache_fail "user-manager-bus key ${key@Q} has no reviewed probe" ;;
      esac
      ;;
    user-manager-unit)
      case "$key" in
        podman-socket-unit-present) capability_with_deadline systemctl --user cat podman.socket ;;
        *) capability_cache_fail "user-manager-unit key ${key@Q} has no reviewed unit" ;;
      esac
      ;;
    *)
      capability_cache_fail "probe kind ${kind@Q} has no reviewed code"
      ;;
  esac
}

# Re-read what was written and check it against the same rules capabilities.tmpl
# applies, so a truncated or reordered record is caught here rather than becoming
# a silent `unavailable` for every consumer.
validate_capability_record() {
  local path=$1 identity=$2 owner_pid=$3 marker=$4 mode index=0
  local schema record_identity record_pid record_marker record_digest rest key token
  [[ -f "$path" && ! -L "$path" ]] || return 1
  mode=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null) || return 1
  [[ "$mode" == 600 ]] || return 1
  {
    IFS=$'\t' read -r schema record_identity record_pid record_marker record_digest rest || return 1
    [[ "$schema" == "$CAPABILITY_CACHE_SCHEMA" ]] || return 1
    [[ -z "$rest" ]] || return 1
    [[ "$record_identity" == "$identity" ]] || return 1
    [[ "$record_pid" == "$owner_pid" ]] || return 1
    [[ "$record_marker" == "$marker" ]] || return 1
    [[ "$record_digest" == "$CAPABILITY_REGISTRY_DIGEST" ]] || return 1
    while IFS=$'\t' read -r key token rest; do
      [[ -z "$rest" ]] || return 1
      ((index < ${#CAPABILITY_KEYS[@]})) || return 1
      [[ "$key" == "${CAPABILITY_KEYS[index]}" ]] || return 1
      [[ "$token" == available || "$token" == unavailable ]] || return 1
      index=$((index + 1))
    done
  } <"$path"
  ((index == ${#CAPABILITY_KEYS[@]}))
}

# Remove ONLY this identity's record. A record that cannot be removed is reported
# as such: never claim an invalidation that did not happen.
invalidate_capability_record() {
  local record=$1
  [[ -e "$record" ]] || return 0
  rm -f "$record" 2>/dev/null \
    && printf 'install-prerequisites.sh: capability cache: removed %s so no consumer can read it.\n' "$record" >&2 \
    || printf 'install-prerequisites.sh: capability cache: could not remove %s; it is STALE and must not be trusted.\n' "$record" >&2
  return 0
}

# Every fault after the record path is known takes this path: try to remove the
# record this identity may already have published, then stop the command. The order
# matters — invalidate first, fail second — so an exit can never leave a token this
# command did not resolve where a template would find it.
capability_cache_abort() {
  local record=$1
  shift
  invalidate_capability_record "$record"
  capability_cache_fail "$@"
}

# Records whose owning command has provably ended: the PID is gone, or it exists
# with a DIFFERENT start marker (recycled). Anything else — a live sibling
# command, an unreadable name, a marker we cannot compare — is left alone, because
# deleting another invocation's snapshot mid-render is exactly the corruption this
# cache exists to prevent.
prune_dead_capability_records() {
  local dir=$1 keep=$2 candidate schema record_pid record_marker live
  for candidate in "$dir"/*.tsv; do
    [[ -f "$candidate" && ! -L "$candidate" ]] || continue
    [[ "$candidate" != "$keep" ]] || continue
    IFS=$'\t' read -r schema _ record_pid record_marker _ <"$candidate" || continue
    [[ "$schema" == "$CAPABILITY_CACHE_SCHEMA" ]] || continue
    [[ "$record_pid" =~ ^[0-9]+$ && -n "$record_marker" ]] || continue
    if live=$(CAPABILITY_CACHE_OWNER_PID="$record_pid" capability_cache_identity_emit 2>/dev/null); then
      case "$live" in
        unresolved) rm -f "$candidate" 2>/dev/null || true ;;
        *)
          [[ "$(cut -f3 <<<"$live")" == "$record_marker" ]] || rm -f "$candidate" 2>/dev/null || true
          ;;
      esac
    fi
  done
}

# The optional argument is the source root; the fixtures pass a scratch tree. In a
# real hook run chezmoi exports CHEZMOI_SOURCE_DIR, which is authoritative and
# CWD-independent. The BASH_SOURCE fallback covers a caller that has neither (this
# file always sits at the source root).
write_capability_cache() {
  local source_root=${1:-${CHEZMOI_SOURCE_DIR:-}} helper registry identity_line
  local schema identity owner_pid marker dir record tmp_record perms index key kind platform token host_platform
  if [[ -z "$source_root" ]]; then
    source_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) \
      || capability_cache_fail 'cannot resolve the chezmoi source root'
  fi

  helper="$source_root/.chezmoitemplates/capability-cache-identity.sh"
  registry="$source_root/$CAPABILITY_REGISTRY_RELPATH"
  [[ -f "$helper" ]] || capability_cache_fail "identity helper $helper is missing"

  # shellcheck disable=SC2034 # read by the sourced helper to suppress its emit.
  CAPABILITY_CACHE_IDENTITY_MAIN=0
  # shellcheck source=.chezmoitemplates/capability-cache-identity.sh
  source "$helper"
  unset CAPABILITY_CACHE_IDENTITY_MAIN

  read_capability_registry "$registry"

  case "$(uname -s)" in
    Linux) host_platform=linux ;;
    *) host_platform=other ;;
  esac

  # $PPID here is chezmoi itself — chezmoi execs this hook directly — which is the
  # same process every template read resolves through its own `output sh -c` child.
  identity_line=$(CAPABILITY_CACHE_OWNER_PID="$PPID" capability_cache_identity_emit)
  IFS=$'\t' read -r schema owner_pid marker identity <<<"$identity_line"
  [[ "$schema" == "$CAPABILITY_CACHE_SCHEMA" && -n "$identity" ]] \
    || capability_cache_fail "could not derive this command's identity (helper said ${identity_line@Q})"

  dir="${XDG_CACHE_HOME:-$HOME/.cache}/chezmoi/capabilities"
  record="$dir/$identity.tsv"

  if [[ ! -d "$dir" ]]; then
    mkdir -p "${dir%/*}" 2>/dev/null || capability_cache_abort "$record" "cannot create ${dir%/*}"
    # A concurrent chezmoi command may win this race; the verification below is the
    # single arbiter either way, so losing it is not itself a failure.
    mkdir -m 700 "$dir" 2>/dev/null || true
  fi
  [[ -d "$dir" && ! -L "$dir" ]] || capability_cache_abort "$record" "$dir is missing or not a directory"
  [[ -O "$dir" ]] || capability_cache_abort "$record" "$dir is not owned by this user"
  perms=$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir" 2>/dev/null) \
    || capability_cache_abort "$record" "cannot read the mode of $dir"
  # Owner-only is a safety property, so it is VERIFIED, not repaired: chmod-ing the
  # directory would also paper over an unwritable-directory fault, which must stop
  # the command instead of being published over.
  [[ "$perms" == 700 ]] || capability_cache_abort "$record" "$dir must be mode 0700, found 0$perms"

  rm -f "$record" 2>/dev/null || capability_cache_abort "$record" "cannot replace $record"

  tmp_record=$(mktemp "$dir/.tmp-$identity.XXXXXX" 2>/dev/null) \
    || capability_cache_abort "$record" "cannot create a temporary record in $dir"
  chmod 600 "$tmp_record" 2>/dev/null || {
    rm -f "$tmp_record" 2>/dev/null || true
    capability_cache_abort "$record" "cannot restrict $tmp_record to owner-only"
  }

  {
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$CAPABILITY_CACHE_SCHEMA" "$identity" "$owner_pid" "$marker" "$CAPABILITY_REGISTRY_DIGEST"
    for index in "${!CAPABILITY_KEYS[@]}"; do
      key=${CAPABILITY_KEYS[index]}
      kind=${CAPABILITY_KINDS[index]}
      platform=${CAPABILITY_PLATFORMS[index]}
      # Inapplicable probes publish unavailable without entering their resolver.
      if [[ "$platform" != any && "$platform" != "$host_platform" ]]; then
        token=unavailable
      elif resolve_capability "$key" "$kind"; then
        token=available
      else
        token=unavailable
      fi
      printf '%s\t%s\n' "$key" "$token"
    done
  } >"$tmp_record" || {
    rm -f "$tmp_record" 2>/dev/null || true
    capability_cache_abort "$record" "cannot write $tmp_record"
  }

  validate_capability_record "$tmp_record" "$identity" "$owner_pid" "$marker" || {
    rm -f "$tmp_record" 2>/dev/null || true
    capability_cache_abort "$record" "the record this command just wrote does not validate"
  }

  mv -f "$tmp_record" "$record" 2>/dev/null || {
    rm -f "$tmp_record" 2>/dev/null || true
    capability_cache_abort "$record" "cannot publish $record"
  }

  validate_capability_record "$record" "$identity" "$owner_pid" "$marker" \
    || capability_cache_abort "$record" "the published record at $record does not validate"

  prune_dead_capability_records "$dir" "$record"
  return 0
}

# Unit-test seam: let the harness `source` this file for its functions without
# running the installer below. No-op in normal execution (variable unset).
if [[ -n "${_INSTALL_PREREQUISITES_TEST_SOURCE:-}" ]]; then
  return 0
fi

# Seed the config-secrets key early (best-effort) — see ensure_config_secrets_key
# above for why the first-init prompt does NOT rely on this hook (the config
# template renders before it and seeds the key itself via
# config-secrets-key-ensure.tmpl). Run it BEFORE the fast path so a fully
# provisioned host still refreshes it on its next command. One keyring read per
# hook run; soft-skips real containers (no keyring there, and the container
# CLI-only profile deploys no secret consumers anyway).
if ! is_container; then
  ensure_config_secrets_key
fi

# Refresh the host-fact cache the templates read (see the block above). Must
# precede the fast path — a provisioned host exits there, and every chezmoi
# command still needs current facts — and must run in containers too, where the
# probes simply resolve to container-appropriate values.
write_facts_cache

# Take this command's capability snapshot. Same placement rule as the fact cache —
# before the fast path, on every host — but with the opposite failure policy: this
# one exits non-zero rather than let a template read a record another command
# published.
write_capability_cache "${CHEZMOI_SOURCE_DIR:-}"

# Fast path: nothing to do once mise is present and `op` can resolve secrets.
# Keeps re-runs cheap — chezmoi invokes this hook on every `init`/`apply`.
if command -v mise >/dev/null 2>&1 && op_ready; then
  exit 0
fi

# Inside a container we NEVER install packages or the 1Password desktop app —
# the base image plus mise are expected to provide `op` and `mise`, and secrets
# come from a service-account token. Fail fast with guidance instead of trying
# to dnf/brew inside the container.
if is_container; then
  missing=()
  command -v op   >/dev/null 2>&1 || missing+=("op (1Password CLI)")
  command -v mise >/dev/null 2>&1 || missing+=("mise")
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'install-prerequisites.sh: container detected, but missing from the base image: %s.\n' "${missing[*]}" >&2
    printf 'Bake op + mise into the image; this hook never installs packages inside a container.\n' >&2
    exit 1
  fi
  printf 'install-prerequisites.sh: container detected, but op is not authenticated.\n' >&2
  printf 'Export a 1Password service-account token before applying:\n' >&2
  printf '  export OP_SERVICE_ACCOUNT_TOKEN=...   # see: op service account create --help\n' >&2
  exit 1
fi

# Fedora: install via dnf (1Password's
# stable RPM repo). Skips work that is already done so the hook is idempotent
# across re-runs.
install_fedora() {
  # Use sudo only when not already root (matches the package-install script).
  # Throw early if neither root nor sudo is available — dnf needs it.
  local -a SUDO
  if [[ "${EUID}" -eq 0 ]]; then
    SUDO=()
  elif command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  else
    printf 'install-prerequisites.sh: requires root or sudo for package installation.\n' >&2
    exit 1
  fi

  if ! rpm -q 1password 1password-cli >/dev/null 2>&1; then
    "${SUDO[@]}" tee /etc/yum.repos.d/1password.repo >/dev/null <<'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey="https://downloads.1password.com/linux/keys/1password.asc"
EOF
    "${SUDO[@]}" dnf install 1password 1password-cli -y
  fi

  if ! rpm -q gh zsh git-lfs >/dev/null 2>&1; then
    "${SUDO[@]}" dnf install gh zsh git-lfs -y
  fi

  # mise, the same bootstrap responsibility install_ubuntu discharges through
  # extrepo. Fedora had no equivalent, so the fast path above ("nothing to do
  # once mise is present") could never be reached on a fresh Fedora host, and
  # `mise-trust` recorded a transient-blocking wait on a tool nothing here was
  # going to install.
  #
  # COPR, because Fedora's own repositories do not carry mise and this is the
  # source jdx (mise's author) publishes for Fedora. `dnf copr enable` is the
  # same mechanism 30-components/80-devtools and the keyd installer already use.
  # Package signatures are checked as usual; COPR does not sign repository
  # METADATA, which is a property of every COPR this repository consumes and not
  # a check disabled here.
  #
  # NOT THE SAME BINARY AS THE MANAGED COMMAND, and deliberately so. The
  # release-locked mise in .chezmoiexternals/dev-tools.toml is what
  # ~/.local/bin/mise points at, and this hook prepends ~/.local/bin to PATH, so
  # the pinned one keeps winning once an apply has run. The RPM exists only to
  # break the bootstrap cycle -- mise has to be on PATH before the source state
  # that delivers mise is read -- exactly as the apt mise does on Ubuntu.
  if ! rpm -q mise >/dev/null 2>&1; then
    "${SUDO[@]}" dnf copr enable -y jdxcode/mise
    "${SUDO[@]}" dnf install -y mise
  fi
}

# Ubuntu: install via apt. Two upstream constraints shape this, neither visible
# from the code:
#
#   * The 1Password DESKTOP app has no arm64 deb or rpm repository — the aarch64
#     tarball is the only artifact — so the 20-linux-ubuntu phase delivers it from
#     the release lock. Only the CLI comes from apt; its repo does publish arm64.
#   * mise comes from `extrepo`, which the vendor documents for Debian 11+ and
#     Ubuntu 22.04+. The PPA is reserved for Ubuntu 26.04 and later.
#
# The package list is the closure of every binary a later phase HARD-FAILS without:
# kitty's installer needs curl/tar/xz/sha256sum, the WakaTime keyring script needs
# secret-tool, the GPG import needs gpg + expect, and the authd login-shell
# fallback needs sqlite3. Dropping one turns a soft skip into an abort.
install_ubuntu() {
  local -a SUDO
  if [[ "${EUID}" -eq 0 ]]; then
    SUDO=()
  elif command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  else
    printf 'install-prerequisites.sh: requires root or sudo for package installation.\n' >&2
    exit 1
  fi

  # `dpkg-query -W` also succeeds for a purged package still in `deinstall ok
  # config-files`, so it would report removed packages as present and never
  # restore them. Require the installed status field instead.
  apt_installed() {
    local status
    status="$(dpkg-query -f '${db:Status-Status}' -W "$1" 2>/dev/null)" || return 1
    [[ "$status" == installed ]]
  }

  local arch
  arch="$(dpkg --print-architecture)"

  if ! apt_installed 1password-cli; then
    "${SUDO[@]}" install -d -m 0755 /usr/share/keyrings
    curl -sS https://downloads.1password.com/linux/keys/1password.asc |
      "${SUDO[@]}" gpg --dearmor --yes --output /usr/share/keyrings/1password-archive-keyring.gpg
    printf 'deb [arch=%s signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/%s stable main\n' \
      "$arch" "$arch" | "${SUDO[@]}" tee /etc/apt/sources.list.d/1password.list >/dev/null
    # debsig verification material, per the vendor's documented apt setup.
    "${SUDO[@]}" install -d -m 0755 /etc/debsig/policies/AC2D62742012EA22 /usr/share/debsig/keyrings/AC2D62742012EA22
    curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol |
      "${SUDO[@]}" tee /etc/debsig/policies/AC2D62742012EA22/1password.pol >/dev/null
    curl -sS https://downloads.1password.com/linux/keys/1password.asc |
      "${SUDO[@]}" gpg --dearmor --yes --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg
    "${SUDO[@]}" apt-get update
    "${SUDO[@]}" apt-get install -y 1password-cli
  fi

  local -a base=(zsh curl tar xz-utils coreutils libsecret-tools gnupg expect sqlite3 gh git-lfs)
  local -a missing_pkgs=()
  local pkg
  for pkg in "${base[@]}"; do
    apt_installed "$pkg" || missing_pkgs+=("$pkg")
  done
  if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    "${SUDO[@]}" apt-get update
    "${SUDO[@]}" apt-get install -y "${missing_pkgs[@]}"
  fi

  if ! apt_installed mise; then
    apt_installed extrepo || "${SUDO[@]}" apt-get install -y extrepo
    "${SUDO[@]}" extrepo enable mise
    "${SUDO[@]}" apt-get update
    "${SUDO[@]}" apt-get install -y mise
  fi
}

# macOS bootstrap is intentionally narrow: Homebrew plus 1Password. The package
# authority reconciler owns every other formula and cask.
install_macos() (
  set -euo pipefail
  scratch_root=${TMPDIR:-"$HOME/Library/Caches"}
  scratch=$(mktemp -d "${scratch_root%/}/chezmoi-bootstrap.XXXXXX")
  trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM
  if ! command -v brew >/dev/null 2>&1; then
    # Keep this URL and digest in sync with
    # .chezmoiscripts/20-darwin/run_onchange_before_homebrew.sh.tmpl.
    installer="$scratch/homebrew-install.sh"
    curl -fsSL 'https://raw.githubusercontent.com/Homebrew/install/39a0c068274254a7658fd9761d59bce9d0e2151f/install.sh' -o "$installer"
    printf '%s  %s\n' '8ff338091a5e10bb5fc040b38316648110f42feff057ecf9feaab51fd0a13ef9' "$installer" |
      shasum -a 256 -c - >/dev/null
    NONINTERACTIVE=1 /bin/bash "$installer"
  fi
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
  brew list --cask 1password >/dev/null 2>&1 || brew install --cask 1password
  brew list --cask 1password-cli >/dev/null 2>&1 || brew install --cask 1password-cli
)

case "$(uname -s)" in
  Darwin) install_macos ;;
  Linux)
    # Detect distro from /etc/os-release (available on all modern Linux distros).
    distro_id=""
    if [[ -r /etc/os-release ]]; then
      # shellcheck source=/dev/null
      distro_id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
    fi
    case "$distro_id" in
      fedora) install_fedora ;;
      ubuntu) install_ubuntu ;;
      *)
        printf 'install-prerequisites.sh: unsupported Linux distro: %s.\n' "${distro_id:-unknown}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'install-prerequisites.sh: unsupported OS %s.\n' "$(uname -s)" >&2
    exit 1
    ;;
esac

# Packages are installed now, but on a fresh device `op` still is not signed in
# (installing the app/CLI does not authenticate it), so chezmoi would fail on the
# first `onepasswordRead`. Block until the user enables the 1Password CLI
# (interactive), or fail fast with guidance (non-interactive / headless).
ensure_op_authenticated || exit 1

# The source-state read is network-free now (the release lock pins every tool),
# so a missing GitHub token is advisory only. Kept after op auth so the
# `op read` in the guidance actually works.
ensure_github_token
exit 0
