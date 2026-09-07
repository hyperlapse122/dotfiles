#!/usr/bin/env bash
# Prove that no image layer can carry a secret, and that the pod still gets one.
#
# `container` is true at image build AND inside the running pod, so the ignore
# branch alone cannot tell them apart -- excluding a target to keep a credential
# out of a layer would also hide it from the runtime apply that is supposed to
# write it. `opAvailable` is what separates them, and this gate is what proves the
# separation actually holds across the whole tree rather than at the two call
# sites someone remembered.
#
# TWO RENDERS, and both assertions matter:
#   build   (container, no op) -- no resolved secret may appear anywhere.
#   runtime (container, op)    -- the targets the build skipped must now resolve.
#
# Without the second, "no secret in the build" is satisfied just as well by
# excluding the targets outright, which would ship a worker that never gets its
# credentials and fails at first use instead of at build.
#
# The stub `op` prints `dummy-secret`, so an occurrence of that string in the
# build render marks the exact spot a real credential would have landed.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/container-secret-gate.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'container-secret-gate: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'container-secret-gate: ok - %s\n' "$*"; }

command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is required on PATH'

mkdir -p "$scratch/bin"
printf '%s\n' '#!/usr/bin/env bash' 'set -eu' 'case "${1-}" in' \
  '  whoami)    printf "dummy@example.invalid\n" ;;' \
  '  --version) printf "2.0.0\n" ;;' \
  '  vault)     printf "[]\n" ;;' \
  '  item)      printf "%s\n" "{\"fields\":[{\"id\":\"username\",\"label\":\"username\",\"value\":\"dummy-user\"},{\"id\":\"credential\",\"label\":\"credential\",\"value\":\"dummy-secret\"}]}" ;;' \
  '  *)         printf "dummy-secret\n" ;;' \
  'esac' >"$scratch/bin/op"
chmod 0755 "$scratch/bin/op"
printf '[data]\n' >"$scratch/empty.toml"

# One render of the whole container-visible surface. `archive` is the right tool
# rather than execute-template over the source tree: it applies .chezmoiignore, so
# what it emits is exactly what the image would contain. Rendering templates
# directly would flag 10-auth and 80-keys, which resolve secrets by design and
# which the container branch already excludes -- a false positive that would teach
# everyone to ignore this gate. Externals hold URLs and digests, never values;
# encrypted targets are ciphertext in the repository already.
render_tree() {
  local op_available=$1 out=$2 home="$scratch/home-$1"
  rm -rf "$home" "$out"
  mkdir -p "$home" "$out"
  (
    cd -- "$repo_root"
    PATH="$scratch/bin:$PATH" chezmoi \
      --config "$scratch/empty.toml" --source "$repo_root" --destination "$out" \
      --override-data '{"chezmoi":{"os":"linux","arch":"amd64","username":"fx","osRelease":{"id":"fedora"},"homeDir":"'"$home"'"},"renderOverrides":{"container":true,"opAvailable":'"$op_available"'}}' \
      archive --format tar --exclude=externals,encrypted 2>"$scratch/archive-$1.err"
  ) | tar -x -C "$out" 2>/dev/null \
    || fail "the container render failed (opAvailable=$op_available); see $scratch/archive-$1.err"
}

render_tree false "$scratch/build"
render_tree true "$scratch/runtime"
pass 'both container renders completed'

# --- 1. No secret in the build render.
leaks=$(grep -rl 'dummy-secret' "$scratch/build" 2>/dev/null || true)
if [[ -n "$leaks" ]]; then
  printf 'container-secret-gate: a resolved secret reached the build render:\n' >&2
  while IFS= read -r f; do
    printf '  %s\n' "${f#"$scratch/build"/}" >&2
    grep -n 'dummy-secret' "$f" | head -3 | sed 's/^/      /' >&2
  done <<<"$leaks"
  fail 'at least one target resolves an op:// reference at image-build time'
fi
pass 'no resolved secret appears anywhere in the build render'

# base64 of `dummy-user:dummy-secret` -- the registry auth shape, which would not
# match a plain grep for the secret.
b64=$(printf 'dummy-user:dummy-secret' | base64 -w0)
grep -rq "$b64" "$scratch/build" 2>/dev/null \
  && fail 'a base64 user:credential pair reached the build render'
pass 'no base64-composed credential appears in the build render'

# --- 2. The runtime render DOES resolve. Otherwise the build is clean only
# because the targets were excluded, and the worker never gets its secrets.
resolved=$(grep -rl 'dummy-secret' "$scratch/runtime" 2>/dev/null | wc -l)
((resolved > 0)) || fail \
  'the runtime render resolves nothing; the op targets are excluded rather than deferred, so a pod would never receive its credentials'
pass "the runtime render resolves secrets in $resolved rendered target(s)"

# --- 3. Every target that differs between the two renders must differ ONLY by
# having gained a resolved secret. A target that appears in one render and not the
# other is a target the pod's apply would never write.
missing=$(comm -23 \
  <(cd "$scratch/runtime" && find . -type f | sort) \
  <(cd "$scratch/build" && find . -type f | sort))
[[ -z "$missing" ]] || fail "these targets exist only in the runtime render, so the build would not create them for the pod to update: $(tr '\n' ' ' <<<"$missing")"
pass 'the two renders cover the same target set'

printf 'container-secret-gate: OK\n'
