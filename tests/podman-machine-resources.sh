#!/usr/bin/env bash
# Usage: bash tests/podman-machine-resources.sh <podman-machine-resources executable>
#
# Drives the helper against a stub podman that reports a machine's memory and
# CPUs and records every call: matching values change nothing, an absent
# machine changes nothing, a changed value stops the machine and sets it
# without starting it, a set that loses the race to the watchdog is retried,
# and one that always loses fails after the retry bound.
set -euo pipefail

helper=$1
fail=0
bad() { echo "podman-machine-resources: $*" >&2; fail=1; }

# The stub reads its state from files in $STUB: `inspect` holds the
# "<memory> <cpus>" inspect prints (absent means no machine), `set-failures`
# how many sets fail before one succeeds, and `calls` collects each call.
stub=$(mktemp -d)
# The build sandbox has no /usr/bin/env, so the stub names this bash.
printf '#!%s\n' "$BASH" > "$stub/podman"
cat >> "$stub/podman" <<'EOF'
echo "$*" >> "$STUB/calls"
case "$2" in
  inspect)
    [ -f "$STUB/inspect" ] || exit 125
    cat "$STUB/inspect"
    ;;
  set)
    failures=$(cat "$STUB/set-failures" 2>/dev/null || echo 0)
    if [ "$failures" -gt 0 ]; then
      echo $((failures - 1)) > "$STUB/set-failures"
      echo "Error: unable to change settings unless vm is stopped" >&2
      exit 125
    fi
    ;;
esac
EOF
chmod +x "$stub/podman"

scenario() {
  STUB=$(mktemp -d)
  export STUB
  [ -z "$1" ] || printf '%s\n' "$1" > "$STUB/inspect"
  printf '%s\n' "$2" > "$STUB/set-failures"
}
calls() { grep -v ' inspect ' "$STUB/calls" 2>/dev/null | tr '\n' ';' || true; }

scenario "8192 4" 0
"$helper" "$stub/podman" vm 8192 4 || bad "matching values failed"
[ -z "$(calls)" ] || bad "matching values still ran: $(calls)"

scenario "" 0
"$helper" "$stub/podman" vm 8192 4 || bad "an absent machine failed"
[ -z "$(calls)" ] || bad "an absent machine still ran: $(calls)"

scenario "8192 4" 0
"$helper" "$stub/podman" vm 12288 4 2>/dev/null || bad "a memory change failed"
[ "$(calls)" = "machine stop vm;machine set --memory 12288 --cpus 4 vm;" ] \
  || bad "a memory change ran: $(calls)"

scenario "8192 4" 1
"$helper" "$stub/podman" vm 8192 6 2>/dev/null || bad "a set retried after the watchdog restart failed"
[ "$(calls)" = "machine stop vm;machine set --memory 8192 --cpus 6 vm;machine stop vm;machine set --memory 8192 --cpus 6 vm;" ] \
  || bad "a lost race ran: $(calls)"

scenario "8192 4" 99
if "$helper" "$stub/podman" vm 12288 4 2>/dev/null; then bad "a set that always fails succeeded"; fi
sets=$(grep -cs ' set ' "$STUB/calls" || true)
[ "$sets" = 3 ] || bad "a set that always fails was tried ${sets:-0} times, not 3"

if grep -qsx 'machine start vm' "$STUB/calls"; then bad "the helper started the machine"; fi

[ "$fail" = 0 ] || exit 1
echo "podman-machine-resources: all scenarios passed"
