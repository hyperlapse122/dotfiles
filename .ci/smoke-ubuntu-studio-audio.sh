#!/usr/bin/env bash
# .ci/smoke-ubuntu-studio-audio.sh
#
# Self-contained smoke test for Ubuntu Studio pro-audio provisioning. Proves,
# inside a real ubuntu:26.04 (resolute) container:
#   1. the 4 pinned pro-audio packages RESOLVE from universe,
#   2. a pure-config package among them REALLY installs noninteractive,
#   3. the audio group exists,
#   4. the repo-owned @audio realtime limits drop-in has valid syntax.
#
# Run locally or in CI identically:
#   podman run --rm -v "$PWD":/repo:ro ubuntu:26.04 bash /repo/.ci/smoke-ubuntu-studio-audio.sh
#
# Self-contained: installs its own add-apt-repository prerequisite
# (software-properties-common) and enables universe itself, so local and CI
# runs behave identically without external setup.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> apt-get update (initial)"
apt-get update

echo "==> installing software-properties-common (provides add-apt-repository)"
apt-get install -y software-properties-common

echo "==> enabling universe"
add-apt-repository -y universe

echo "==> apt-get update (post-universe)"
apt-get update

PRO_AUDIO_PKGS=(
  ubuntustudio-audio-core
  ubuntustudio-pipewire-config
  ubuntustudio-performance-tweaks
  ubuntustudio-lowlatency-settings
)

echo "==> simulating install of pro-audio packages (resolution proof)"
# `|| true` keeps set -e from aborting here on apt-get -s exit 100 (unlocatable
# package), so the resolution assertions below actually run instead of being dead
# code. Same idiom as dpkg_status below.
sim_output="$(apt-get -s install "${PRO_AUDIO_PKGS[@]}" 2>&1 || true)"
echo "${sim_output}"

if grep -q "Unable to locate package" <<<"${sim_output}"; then
  echo "SMOKE FAIL: one or more pro-audio packages could not be located" >&2
  exit 1
fi

for pkg in "${PRO_AUDIO_PKGS[@]}"; do
  if ! grep -qE "(Inst|Conf) ${pkg} " <<<"${sim_output}"; then
    echo "SMOKE FAIL: ${pkg} missing from simulated action set" >&2
    exit 1
  fi
done

echo "==> real noninteractive install proof: ubuntustudio-pipewire-config"
if ! apt-get install -y ubuntustudio-pipewire-config; then
  echo "SMOKE FAIL: real install of ubuntustudio-pipewire-config failed" >&2
  exit 1
fi

dpkg_status="$(dpkg -s ubuntustudio-pipewire-config 2>&1 || true)"
if ! grep -q "^Status: install ok installed$" <<<"${dpkg_status}"; then
  echo "SMOKE FAIL: ubuntustudio-pipewire-config not reported install ok installed" >&2
  echo "${dpkg_status}" >&2
  exit 1
fi
echo "==> ubuntustudio-pipewire-config: install ok installed (postinst warnings, if any, tolerated)"

echo "==> asserting audio group exists"
if ! getent group audio >/dev/null; then
  echo "SMOKE FAIL: audio group does not exist on this image" >&2
  exit 1
fi

echo "==> validating @audio realtime limits drop-in syntax"
limits_file=/repo/system/linux/etc/security/limits.d/95-ubuntustudio-audio.conf
if [[ ! -f "${limits_file}" ]]; then
  echo "SMOKE FAIL: ${limits_file} not found" >&2
  exit 1
fi
bad_lines="$(grep -vE '^\s*(#.*)?$' "${limits_file}" | grep -vE '^@audio[[:space:]]+-[[:space:]]+(rtprio|memlock|nice)[[:space:]]+\S+$' || true)"
if [[ -n "${bad_lines}" ]]; then
  echo "SMOKE FAIL: malformed limits.d line(s):" >&2
  echo "${bad_lines}" >&2
  exit 1
fi

echo "SMOKE OK"
