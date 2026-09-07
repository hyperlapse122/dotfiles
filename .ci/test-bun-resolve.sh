#!/usr/bin/env bash
# Guards the bun resolution ladder shared by every script that compiles with bun.
#
# There are two copies of that ladder, and the split is deliberate: a .ci gate
# runs outside chezmoi's templating and cannot include a chezmoi partial, so
# `.chezmoitemplates/bun-resolve.sh.tmpl` and `.ci/lib/bun.sh` implement the same
# four rungs twice. This gate is what keeps the second copy honest.
#
# `.ci/test-build-command-reconcile.sh` already drives the templated copy through
# a rendered build script. Nothing exercised the .ci copy: all four of its callers
# run where CI has already put bun on PATH, so rung 1 answers before the fallback
# rungs are ever reached, and deleting them would leave the suite green.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
partial="$repo_root/.chezmoitemplates/bun-resolve.sh.tmpl"
lib="$repo_root/.ci/lib/bun.sh"

scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/bun-resolve-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'bun-resolve gate: %s\n' "$*" >&2; exit 1; }
pass() { printf 'bun-resolve gate: %s\n' "$*"; }

# The rung list is the part that must not drift. Both files spell each candidate
# on its own line inside the same `for` word list, so the ordered set of paths is
# comparable even though one copy is a function with `local` and the other is
# inlined shell that unsets its loop variable.
rungs_of() {
  sed -n '/for bun_candidate in/,/; do/p' "$1" |
    grep -o '"\$[A-Za-z_(][^"]*"' |
    sed 's/[[:space:]]*$//'
}

partial_rungs=$(rungs_of "$partial")
lib_rungs=$(rungs_of "$lib")
[[ -n "$partial_rungs" ]] || fail "could not read the rung list out of $partial"
[[ -n "$lib_rungs" ]] || fail "could not read the rung list out of $lib"
[[ "$partial_rungs" == "$lib_rungs" ]] || {
  printf 'bun-resolve gate: the two ladders have drifted\n' >&2
  diff <(printf '%s\n' "$partial_rungs") <(printf '%s\n' "$lib_rungs") >&2 || true
  exit 1
}
pass 'both ladders declare the same rungs in the same order'

# Rung 1 is the only candidate the ladder does not spell out itself, so it is the
# only one that can arrive relative. Both copies must reject a non-absolute hit,
# and the rung list compared above cannot see that guard: it lives in the loop
# body, not in the word list.
for ladder in "$partial" "$lib"; do
  grep -qF '"$bun_candidate" == /*' "$ladder" ||
    fail "$ladder does not require an absolute rung-1 candidate"
done
pass 'both ladders require an absolute candidate'

# A bun stand-in that records the path it was executed from, so a case can prove
# WHICH rung answered rather than merely that something answered.
write_fake_bun() {
  local path=$1
  mkdir -p "${path%/*}"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$path"
  chmod 0755 "$path"
}

# Each case runs in a fresh HOME with PATH holding only the tools the function
# itself needs, so the runner's own bun can never satisfy a fallback rung.
resolve_in() {
  local home=$1 extra_path=${2:-}
  local bin="$scratch/bin"
  mkdir -p "$bin"
  local tool
  for tool in bash env; do
    ln -sf "$(command -v "$tool")" "$bin/$tool"
  done
  env HOME="$home" PATH="${extra_path:+$extra_path:}$bin" /usr/bin/bash -c '
    set -euo pipefail
    source "$1"
    resolve_bun
    printf "%s\n%s\n" "$BUN_BIN" "$PATH"
  ' _ "$lib"
}

case_home() {
  local home="$scratch/$1"
  rm -rf -- "$home"
  mkdir -p "$home"
  printf '%s' "$home"
}

# Rung 2: the public link, with nothing on PATH.
home=$(case_home rung2)
write_fake_bun "$home/.local/bin/bun"
got=$(resolve_in "$home" | head -1)
[[ "$got" == "$home/.local/bin/bun" ]] || fail "rung 2 resolved $got"
pass 'rung 2 resolves the public link when bun is off PATH'

# Rung 3: the current command generation.
home=$(case_home rung3)
write_fake_bun "$home/.local/lib/commands/current/bun/bun"
got=$(resolve_in "$home" | head -1)
[[ "$got" == "$home/.local/lib/commands/current/bun/bun" ]] || fail "rung 3 resolved $got"
pass 'rung 3 resolves the current generation'

# Rung 4: the staging path an external writes before any link exists.
home=$(case_home rung4)
write_fake_bun "$home/.local/share/chezmoi-commands/incomplete/bun/bun"
got=$(resolve_in "$home" | head -1)
[[ "$got" == "$home/.local/share/chezmoi-commands/incomplete/bun/bun" ]] || fail "rung 4 resolved $got"
pass 'rung 4 resolves the staging path'

# Ordering: none of these three is reachable from PATH, so only the ladder's own
# candidate order can decide between them. Reorder the list and this fails.
home=$(case_home ordering)
write_fake_bun "$home/.local/bin/bun"
write_fake_bun "$home/.local/lib/commands/current/bun/bun"
write_fake_bun "$home/.local/share/chezmoi-commands/incomplete/bun/bun"
got=$(resolve_in "$home" | head -1)
[[ "$got" == "$home/.local/bin/bun" ]] || fail "ordering resolved $got, expected the public link"
pass 'an earlier rung wins over the later ones'

# Nothing found: empty BUN_BIN, untouched PATH, and no failure of its own. The
# callers decide whether an absent bun is fatal, a skip, or a fallback.
home=$(case_home absent)
out=$(resolve_in "$home")
[[ -z "$(printf '%s' "$out" | head -1)" ]] || fail "absent case resolved $(printf '%s' "$out" | head -1)"
pass 'no rung matching leaves BUN_BIN empty without failing'

# The PATH prepend is load-bearing for the `bun build` grandchild `vp run build`
# spawns, and it must not stack up on repeat calls.
home=$(case_home dedup)
write_fake_bun "$home/.local/bin/bun"
path_out=$(env HOME="$home" PATH="$scratch/bin" /usr/bin/bash -c '
  set -euo pipefail
  source "$1"
  resolve_bun
  resolve_bun
  printf "%s\n" "$PATH"
' _ "$lib")
occurrences=$(printf '%s' "$path_out" | tr ':' '\n' | grep -cxF "$home/.local/bin")
[[ "$occurrences" -eq 1 ]] || fail "PATH carries $home/.local/bin $occurrences times, expected 1"
pass 'the resolved directory is prepended once, not once per call'

# A bun already on PATH answers first and is not re-prepended.
home=$(case_home onpath)
mkdir -p "$home/ambient"
write_fake_bun "$home/ambient/bun"
write_fake_bun "$home/.local/bin/bun"
got=$(resolve_in "$home" "$home/ambient" | head -1)
[[ "$got" == "$home/ambient/bun" ]] || fail "on-PATH case resolved $got"
pass 'a bun already on PATH answers at rung 1'

# A PATH carrying an empty element makes `command -v bun` answer with a relative
# `./bun`. Accepting that rung would set BUN_DIR to `.` and prepend the working
# directory to PATH for every command the caller runs afterwards. The rung is
# rejected instead, and rung 2 answers.
home=$(case_home relative)
mkdir -p "$home/cwd"
write_fake_bun "$home/cwd/bun"
write_fake_bun "$home/.local/bin/bun"
mkdir -p "$scratch/bin"
out=$(cd "$home/cwd" && env HOME="$home" PATH=":$scratch/bin" /usr/bin/bash -c '
  set -euo pipefail
  source "$1"
  resolve_bun
  printf "%s\n%s\n" "$BUN_BIN" "$PATH"
' _ "$lib")
got=$(printf '%s' "$out" | head -1)
[[ "$got" == "$home/.local/bin/bun" ]] || fail "a relative rung-1 hit resolved $got"
if printf '%s' "$out" | tail -1 | tr ':' '\n' | grep -qxF '.'; then
  fail 'a relative rung-1 hit put the working directory on PATH'
fi
pass 'a relative rung-1 candidate is rejected and rung 2 answers'

printf 'bun-resolve gate: all cases passed\n'
