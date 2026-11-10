#!/usr/bin/env bash
# Usage: bash tests/minikube-darwin-start.sh <minikube-darwin-start executable>
#
# Drives the login helper against stub podman and minikube binaries: it waits
# until `podman info` answers and then starts the cluster once with the
# pinned profile, driver, and runtime and the size it is given; it gives up
# with a failure, without calling minikube, when Podman never answers in
# time, including when `podman info` itself hangs; and a failing
# `minikube start` fails the helper so launchd retries it.
set -euo pipefail

helper=$1
fail=0
bad() { echo "minikube-darwin-start: $*" >&2; fail=1; }

# `info-failures` holds how many `podman info` calls fail before one
# succeeds; `minikube-status` is the exit status of minikube; `calls`
# collects every call.
stub=$(mktemp -d)
# The build sandbox has no /usr/bin/env, so the stub names this bash.
printf '#!%s\n' "$BASH" > "$stub/podman"
cat >> "$stub/podman" <<'EOF'
echo "podman $*" >> "$STUB/calls"
# A machine that accepts the connection but never answers.
[ ! -e "$STUB/hang" ] || exec sleep 30
failures=$(cat "$STUB/info-failures")
if [ "$failures" -gt 0 ]; then
  echo $((failures - 1)) > "$STUB/info-failures"
  exit 125
fi
EOF
printf '#!%s\n' "$BASH" > "$stub/minikube"
cat >> "$stub/minikube" <<'EOF'
echo "minikube $*" >> "$STUB/calls"
exit "$(cat "$STUB/minikube-status")"
EOF
chmod +x "$stub/podman" "$stub/minikube"

scenario() {
  STUB=$(mktemp -d)
  export STUB
  printf '%s\n' "$1" > "$STUB/info-failures"
  printf '%s\n' "$2" > "$STUB/minikube-status"
}
count() {
  local n
  n=$(grep -cs "$1" "$STUB/calls") || true
  echo "${n:-0}"
}
starts() { count '^minikube '; }

scenario 2 0
"$helper" "$stub/podman" "$stub/minikube" 10 0 4096 2 || bad "a start after Podman answered failed"
[ "$(count '^podman info')" = 3 ] || bad "the helper did not wait for podman info"
[ "$(starts)" = 1 ] || bad "minikube was started $(starts) times, not once"
start=$(grep -s '^minikube ' "$STUB/calls" || true)
for flag in start --profile=minikube --driver=podman --container-runtime=containerd --memory=4096 --cpus=2; do
  case " $start " in
    *" $flag "*) ;;
    *) bad "minikube start lacks $flag: $start" ;;
  esac
done

scenario 999 0
if "$helper" "$stub/podman" "$stub/minikube" 1 1 4096 2 2>/dev/null; then bad "a Podman that never answered succeeded"; fi
[ "$(starts)" = 0 ] || bad "minikube was started though Podman never answered"

scenario 0 0
touch "$STUB/hang"
began=$SECONDS
if "$helper" "$stub/podman" "$stub/minikube" 2 1 4096 2 2>/dev/null; then bad "a hung podman info succeeded"; fi
[ $((SECONDS - began)) -lt 10 ] || bad "a hung podman info held the helper for $((SECONDS - began))s past its 2s bound"
[ "$(starts)" = 0 ] || bad "minikube was started though podman info hung"

scenario 0 1
if "$helper" "$stub/podman" "$stub/minikube" 10 0 4096 2 2>/dev/null; then bad "a failing minikube start succeeded"; fi
[ "$(starts)" = 1 ] || bad "the failing-start scenario never reached minikube start"

[ "$fail" = 0 ] || exit 1
echo "minikube-darwin-start: all scenarios passed"
