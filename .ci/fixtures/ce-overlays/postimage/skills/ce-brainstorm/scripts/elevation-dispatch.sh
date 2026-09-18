#!/usr/bin/env bash
# Fixture stand-in for the upstream elevation adapter.
set -uo pipefail

log() { printf '[elevation] %s\n' "$*" >&2; }

EFFORT="@AUTHORING_EFFORT@"   # this repository holds elevation at the roster's authoring effort

ALLOWED=(Read Glob Grep)

build_cmd() {
  local tools
  tools=$(IFS=,; printf '%s' "${ALLOWED[*]}")
  CMD=(claude -p --model "$1" --effort "$EFFORT" --tools "$tools")
}

MODEL="${1:?model required}"
build_cmd "$MODEL"
log "would run: ${CMD[*]}"
