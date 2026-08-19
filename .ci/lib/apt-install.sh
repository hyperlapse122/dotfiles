#!/usr/bin/env bash
set -euo pipefail

# Two runner facts the call sites cannot express:
#
#   1. Some of these packages ship in the runner image already, so a present
#      binary short-circuits instead of spending the network for nothing.
#   2. GitHub's Azure-hosted runners default to azure.archive.ubuntu.com, which
#      goes unreachable often enough to matter. apt then retries it for minutes
#      while the canonical archive.ubuntu.com answers immediately, so a job that
#      needed one package wedges until its timeout. Repointing the sources first
#      turns that wedge into a normal install, and every apt call is bounded so
#      a mirror that stalls anyway fails fast instead of eating the job budget.
usage='usage: apt-install.sh COMMAND|- PACKAGE [PACKAGE...]'
command_name=${1:?$usage}
shift
[ "$#" -gt 0 ] || {
  printf 'apt-install: no packages given\n%s\n' "$usage" >&2
  exit 1
}

# A library package has no binary to probe, so `-` installs unconditionally.
if [ "$command_name" != '-' ] && command -v "$command_name" >/dev/null; then
  printf 'apt-install: %s already present; skipping apt\n' "$command_name"
  exit 0
fi

# The image selects its mirror through a mirrorlist, so the dead host has to be
# dropped there; the sources files are a fallback for images that inline it.
mirrorlist=/etc/apt/apt-mirrors.txt
if [ -f "$mirrorlist" ]; then
  sudo sed -i '/azure\.archive\.ubuntu\.com/d' "$mirrorlist"
  grep -q '://' "$mirrorlist" ||
    printf 'https://archive.ubuntu.com/ubuntu/\n' | sudo tee "$mirrorlist" >/dev/null
fi

for src in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
  [ -f "$src" ] || continue
  sudo sed -i 's|http://azure\.archive\.ubuntu\.com/ubuntu|https://archive.ubuntu.com/ubuntu|g' "$src"
done

sudo timeout 180 apt-get update -o Acquire::Retries=3
sudo timeout 180 env DEBIAN_FRONTEND=noninteractive \
  apt-get install -y --no-install-recommends -o Acquire::Retries=3 "$@"

[ "$command_name" = '-' ] || command -v "$command_name" >/dev/null || {
  printf 'apt-install: installed %s but %s is still not on PATH\n' "$*" "$command_name" >&2
  exit 1
}
