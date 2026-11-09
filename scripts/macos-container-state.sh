#!/bin/sh

# container 1.7.1 returns exit 1 with structured output for a stopped API.
# Keep that distinct from an unsupported command or failed inspection.
container_runtime_state() {
    runtime_exit=0
    runtime_json=$(container system status --format json) || runtime_exit=$?
    runtime_state=$(printf '%s\n' "$runtime_json" | jq -er '.status | strings') ||
        fail 'Cannot inspect container runtime status; check `container system status --format json`.'
    case "$runtime_exit:$runtime_state" in
        0:running|1:unregistered|1:'not running') ;;
        *) fail 'Cannot identify container runtime state; check `container system status --format json`.' ;;
    esac
}
