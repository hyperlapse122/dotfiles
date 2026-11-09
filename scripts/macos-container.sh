#!/bin/sh
set -eu

fail() { printf '%s\n' "macOS container: $*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail 'Requires macOS.'
[ "$(uname -m)" = arm64 ] || fail 'Requires native Apple Silicon.'
version=$(sw_vers -productVersion)
major=${version%%.*}
case "$major" in ''|*[!0-9]*) fail 'Cannot identify the macOS version.';; esac
[ "$major" -ge 26 ] || fail 'Requires macOS 26 or later.'
[ "$(brew --prefix)" = /opt/homebrew ] || fail 'Requires native Homebrew at /opt/homebrew.'
. "$(dirname "$0")/macos-container-state.sh"

login_registration() {
    service_json=$(brew services info container --json) || fail 'Cannot inspect the container login service.'
    registered=$(printf '%s\n' "$service_json" | jq -er '
        if type == "array" and length == 1 and .[0].name == "container"
           and (.[0].registered | type) == "boolean"
        then .[0].registered | tostring else error("Invalid container service metadata") end') ||
        fail 'Cannot identify container login registration; check `brew services info container --json`.'
}

container_runtime_state
login_registration
pending="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/container-kernel-pending"
if [ "$runtime_state" = running ] && [ -e "$pending" ]; then
    fail "Previous kernel preparation did not finish and the API may remain running. Complete kernel installation with \`container system kernel set --recommended --force\`, then remove $pending and reapply. Do not replace a kernel while another task depends on it."
fi

if [ "$runtime_state" != running ]; then
    # The kernel installer requires the API. Keep a failure record so the next
    # apply cannot mistake the API left behind for a prepared runtime.
    mkdir -p "$(dirname "$pending")"
    : > "$pending"
    container system start --disable-kernel-install ||
        fail 'Cannot start the container API. Check `container system logs` and reapply.'
    # Without --force, the supported installer fails on an existing kernel.
    # This branch is reached only when the runtime was stopped on entry.
    container system kernel set --recommended --force ||
        fail "Recommended kernel installation failed; the API may remain running and its kernel is unprepared. Resolve the download or installation error, complete \`container system kernel set --recommended --force\`, then remove $pending and reapply."
    rm "$pending"
fi

if [ "$registered" = false ]; then
    # Homebrew start bootstraps its login launcher. The native container start
    # command bootstraps an already loaded API without bootout or kickstart.
    brew services start container ||
        fail 'Cannot register the container login service. Check `brew services info container --json` and reapply.'
    login_registration
    [ "$registered" = true ] || fail 'Container login registration did not persist; check `brew services info container --json`.'
fi

attempt=0
while [ "$attempt" -lt 5 ]; do
    container_runtime_state
    if [ "$runtime_state" = running ]; then
        printf '%s\n' 'Container kernel and login service are ready.'
        exit 0
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -lt 5 ]; then sleep 1; fi
done
fail 'Container API did not respond after startup. Check `container system logs` and reapply.'
