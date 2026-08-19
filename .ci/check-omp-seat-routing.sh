#!/usr/bin/env bash
set -euo pipefail

# The delegation routing table in `.chezmoitemplates/agents-instructions.tmpl`
# directs work to omp's bundled seats. That routing table must remain
# exhaustive and consistent with the bundled agent roster: an agent omp gains
# has no routing guidance unless added to the table, and an agent omp drops
# leaves dead routing guidance in the deployed instruction core. Both
# directions are drift, so this compares the two sets and fails on either
# difference.
#
# Parsing contract: the routing table is a markdown table whose SECOND column
# holds exactly one backtick-enclosed seat name per row. Extract seat names
# only from that column — matching rows shaped like
# `^\| .* \| `<name>` \| .* \|$`. If the extraction finds zero seat names, this
# check fails with a message naming the expected table shape rather than
# reporting a spurious set difference.
#
# It lives in CI rather than the provisioner because the roster is a property of
# the omp RELEASE this repository pins, checked once before merge, not a
# per-host runtime fact.
#
# It needs a real omp binary, so it runs after the locked omp installation in CI.

command -v omp >/dev/null || {
  printf 'check-omp-seat-routing: omp is not on PATH; this check requires the locked binary\n' >&2
  exit 1
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/omp-seat-routing
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT

mkdir -p "$scratch/home" "$scratch/target" "$scratch/bin"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod +x "$scratch/bin/op"
chezmoi_bin=$(type -P chezmoi)

fail() { printf 'check-omp-seat-routing: %s\n' "$*" >&2; exit 1; }
# shellcheck source=.ci/lib/render-gate-helpers.sh
# shellcheck disable=SC1091
source "$repo_root/.ci/lib/render-gate-helpers.sh"

wrapper=dot_omp/private_agent/private_readonly_AGENTS.md.tmpl
require_file "$repo_root" "$scratch" "$chezmoi_bin" "$wrapper"
require_file "$repo_root" "$scratch" "$chezmoi_bin" .chezmoitemplates/agents-instructions.tmpl

rendered="$scratch/AGENTS.md"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$repo_root/$wrapper" "$rendered"
[[ -s $rendered ]] || fail 'wrapper rendered empty'

# Extract seat names from the second column of the markdown routing table.
# shellcheck disable=SC2016
sed -nE 's/^\| .* \| `([a-zA-Z0-9_-]+)` \| .* \|$/\1/p' "$rendered" | sort -u >"$scratch/routed.txt"

routed_count=$(wc -l <"$scratch/routed.txt")
[[ $routed_count -gt 0 ]] || {
  # shellcheck disable=SC2016
  printf 'check-omp-seat-routing: found no seat names in routing table; expected markdown table with backtick-enclosed seat names in column 2 (e.g. | Work shape | `seat` | Access |)\n' >&2
  exit 1
}

# A bare HOME keeps a developer's own agent directory from leaking project or
# user agents into the roster; only the bundled set may answer here.
env -i HOME="$scratch/home" PATH="$PATH" omp agents unpack --dir "$scratch/agents" --json >/dev/null
find "$scratch/agents" -maxdepth 1 -name '*.md' -exec basename {} .md \; | sort -u >"$scratch/bundled.txt"

bundled_count=$(wc -l <"$scratch/bundled.txt")
[[ $bundled_count -gt 0 ]] || {
  printf 'check-omp-seat-routing: omp reported no bundled agents; the comparison would pass vacuously\n' >&2
  exit 1
}

status=0
while IFS= read -r name; do
  [[ -n $name ]] || continue
  printf 'check-omp-seat-routing: omp bundles %s, which the instruction routing table does not route; the seat is unrouted\n' "$name" >&2
  status=1
done < <(comm -23 "$scratch/bundled.txt" "$scratch/routed.txt")
while IFS= read -r name; do
  [[ -n $name ]] || continue
  printf 'check-omp-seat-routing: instruction routing table routes %s, which omp does not bundle; the routing is dead or points to a non-existent seat\n' "$name" >&2
  status=1
done < <(comm -13 "$scratch/bundled.txt" "$scratch/routed.txt")

[[ $status -eq 0 ]] || {
  printf 'check-omp-seat-routing: routed %d, bundled %d; see the differences above\n' \
    "$routed_count" "$bundled_count" >&2
  exit 1
}

printf 'check-omp-seat-routing: %d bundled agents all routed\n' "$bundled_count"
