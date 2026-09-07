#!/usr/bin/env bash
set -euo pipefail

# Requires a `checksum` table on every chezmoi external whose download URL is one
# the release lock recorded a digest for.
#
# WHY A GATE AND NOT A CONVENTION. `.chezmoidata/releases.json` carries a
# per-platform sha256 (or sha512) for every artifact it resolves, and
# `.chezmoitemplates/release-lock-ref.tmpl` already exposes it. Twenty stanzas
# nevertheless downloaded and installed an executable without asserting that
# digest, so chezmoi trusted whatever bytes the URL served. The tables added
# alongside this gate close that; the gate is what keeps the next external from
# reopening it.
#
# WHY IT RENDERS. Coverage cannot be read off the source templates without
# re-implementing the template language, and it cannot be read off the rendered
# TOML alone either: a rendered `url` is a bare string carrying no trace of
# whether it came from the lock. The gate therefore does both halves — it
# renders each `.chezmoiexternals/*.toml` per platform (the loop is modelled on
# `.ci/test-command-external-render.sh`) and matches each stanza's rendered
# `url` against the set of artifact URLs the lock records.
#
# THE EXEMPTION IS KEYED ON THE LOCK, NOT ON A NAME LIST. A stanza is required
# to carry a checksum exactly when its URL matches a lock artifact that has a
# digest. Everything else is silently fine: `kubectl`, `kubectl-convert` and
# `helm` compose a dl.k8s.io/get.helm.sh URL from a version-only lock entry,
# `glab` builds a GitLab release URL, `winbox` builds a MikroTik URL, and the
# agent-skill externals fetch GitHub source archives — none of those URLs is a
# recorded artifact, so no digest exists to assert. A hardcoded tool-name list
# would express the same thing today and be wrong tomorrow: it would keep
# exempting a tool after its lock entry gained artifacts, which is precisely the
# regression this gate exists to catch.
#
# EITHER DIGEST SATISFIES IT. `.ci/check-release-lock-digests.sh` already states
# that rule, because upstreams do not agree on one hash: `agy` records a sha512
# with a null sha256 and is verified through `[agy.checksum] sha512`. A
# sha256-only rule would demand of that unit a digest that does not exist.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tree=${1:-$repo_root}
lock="$tree/.chezmoidata/releases.json"

fail() {
  printf 'check-external-checksum-coverage: %s\n' "$1" >&2
  [ -z "${2:-}" ] || printf '%s\n' "$2" >&2
  printf '::error::%s\n' "$1"
  exit 1
}

command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is not on PATH'
[ -f "$lock" ] || fail "lock not found: $lock"

# The repo's other Python-using gates probe /usr/bin/python3 first because a mise
# or pyenv interpreter earlier on PATH usually lacks the distro modules. Here the
# only requirement is tomllib, which is stdlib from 3.11.
coverage_python=''
for candidate in /usr/bin/python3 python3; do
  command -v "$candidate" >/dev/null 2>&1 || continue
  if "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
    coverage_python=$candidate
    break
  fi
done
[ -n "$coverage_python" ] || fail 'no python3 with tomllib (3.11+) found'

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/agent-scratch
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/external-checksum-coverage.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

# `.chezmoiexternals/system.toml` reaches facts.tmpl, which shells out to `op`
# on some paths; the same stub the render gate uses keeps the render offline.
mkdir -p -- "$scratch/bin" "$scratch/target" "$scratch/rendered"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf '[data]\n' >"$scratch/empty.toml"

# The four platforms every lock-URL-backed external is expected to resolve on.
platforms=(
  "linux:amd64"
  "linux:arm64"
  "darwin:amd64"
  "darwin:arm64"
)

rendered_args=()
for plat in "${platforms[@]}"; do
  IFS=":" read -r os arch <<<"$plat"
  for ext in "$tree/.chezmoiexternals"/*.toml; do
    name=$(basename -- "$ext" .toml)
    out="$scratch/rendered/$os-$arch--$name.toml"
    env PATH="$scratch/bin:$PATH" chezmoi \
      --config "$scratch/empty.toml" --source "$tree" --destination "$scratch/target" \
      --override-data "{\"chezmoi\":{\"os\":\"$os\",\"arch\":\"$arch\"}}" \
      execute-template <"$ext" >"$out" ||
      fail "render failed: .chezmoiexternals/$name.toml on $os-$arch"
    rendered_args+=("$os-$arch|.chezmoiexternals/$name.toml|$out")
  done
done

checker="$scratch/check_coverage.py"
cat <<'PYTHON' >"$checker"
"""Report externals that download a digest-bearing lock artifact unverified.

argv[1] is the lock; each remaining argument is
`<platform>|<source path>|<rendered file>`.
"""
import json
import pathlib
import re
import sys
import tomllib

HEX = {"sha256": re.compile(r"\A[0-9a-f]{64}\Z"), "sha512": re.compile(r"\A[0-9a-f]{128}\Z")}


def main():
    lock = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    tools = (lock.get("releases") or {}).get("tools") or {}

    # url -> ("tool platform" label, digest present). An emulated arch serves the
    # amd64 asset, so one URL can arrive from several platform keys; the digest
    # recorded beside it is the same, so last-wins is safe.
    digested = {}
    undigested = {}
    for tool, entry in sorted(tools.items()):
        for platform, artifact in sorted((entry.get("artifacts") or {}).items()):
            url = artifact.get("url")
            if not url:
                continue
            label = f"{tool} [{platform}]"
            if artifact.get("sha256") or artifact.get("sha512"):
                digested[url] = label
            else:
                undigested.setdefault(url, label)

    if not digested:
        print("the lock records no digested artifact URLs at all", file=sys.stderr)
        return 1

    failures = []
    covered = set()
    for raw in sys.argv[2:]:
        platform, source, path = raw.split("|", 2)
        document = tomllib.loads(pathlib.Path(path).read_text(encoding="utf-8"))
        for name, stanza in document.items():
            if not isinstance(stanza, dict):
                continue
            url = stanza.get("url")
            if not isinstance(url, str) or url not in digested:
                continue
            where = f"{source} [{name}] on {platform} (lock {digested[url]})"
            checksum = stanza.get("checksum")
            if not isinstance(checksum, dict):
                failures.append(
                    f"{where}: downloads a lock artifact that has a digest but "
                    f"declares no [{name}.checksum] table"
                )
                continue
            good = [
                field
                for field, pattern in HEX.items()
                if isinstance(checksum.get(field), str) and pattern.match(checksum[field])
            ]
            if not good:
                failures.append(
                    f"{where}: [{name}.checksum] carries no usable sha256 or "
                    f"sha512 (got {sorted(checksum)})"
                )
                continue
            covered.add(where)

    for line in failures:
        print(line, file=sys.stderr)
    if failures:
        return 1

    if not covered:
        # A render that matched nothing would report clean while proving nothing.
        print(
            "no external matched a digested lock artifact URL; the render or the "
            "lock is broken",
            file=sys.stderr,
        )
        return 1

    print(f"check-external-checksum-coverage: {len(covered)} lock-backed external renders verified")
    return 0


sys.exit(main())
PYTHON

"$coverage_python" "$checker" "$lock" "${rendered_args[@]}" ||
  fail 'externals download digest-bearing lock artifacts without a checksum table (listed above)'

printf 'check-external-checksum-coverage: ok\n'
