#!/usr/bin/env bash
set -euo pipefail

# Drives .ci/check-external-checksum-coverage.sh through its own failure paths.
#
# The gate is the only thing standing between a new external and an unverified
# download, so a gate that reports ok while detecting nothing is worse than no
# gate at all. Every case below mutates a throwaway copy of the source tree and
# asserts the gate rejects it for the stated reason; the real
# `.chezmoiexternals/` and `.chezmoidata/` are never written.
#
# The three rejection cases map one-to-one onto the three ways coverage can be
# lost: the checksum table disappears, the digest is well-formed but wrong, or
# the url drifts off the release lock so the table is no longer demanded at all.
#
# The two acceptance cases pin the shape of the exemption. `kubectl`,
# `kubectl-convert`, `helm`, `glab` and the `winbox` pair compose their URL from
# a version-only lock entry, so no recorded digest exists to assert and the gate
# must stay silent about them. The pinned `agy` artifact uses SHA-256. A separate
# fixture preserves coverage for the retained SHA-512 vendor resolver.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
gate="$repo_root/.ci/check-external-checksum-coverage.sh"

scratch_root=${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/test-external-checksum-coverage.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() {
  printf 'test-check-external-checksum-coverage: %s\n' "$*" >&2
  exit 1
}

pass() { printf '  ok  %s\n' "$*"; }

chezmoi_bin=$(command -v chezmoi) || fail 'chezmoi is not on PATH'
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
source_root=$(resolve_source_root "$repo_root")

# A source tree the gate can render: everything symlinked back to the repo, with
# the two directories the cases mutate copied so the originals stay untouched.
fixture() {
  local name=$1 entry
  local dest="$scratch/fixture-$name"
  rm -rf -- "$dest"
  mkdir -p -- "$dest"
  for entry in "$repo_root"/* "$repo_root"/.[!.]*; do
    [ -e "$entry" ] || continue
    ln -s -- "$entry" "$dest/$(basename -- "$entry")"
  done
  local dest_source_root
  if [[ -f "$dest/.chezmoiroot" ]]; then
    local rel_source
    rel_source=$(resolve_source_root "$dest")
    rm -f -- "$rel_source"
    mkdir -p -- "$rel_source"
    for entry in "$source_root"/* "$source_root"/.[!.]*; do
      [ -e "$entry" ] || continue
      ln -s -- "$entry" "$rel_source/$(basename -- "$entry")"
    done
    dest_source_root="$rel_source"
  else
    dest_source_root="$dest"
  fi
  rm -f -- "$dest_source_root/.chezmoiexternals" "$dest_source_root/.chezmoidata"
  cp -a -L -- "$source_root/.chezmoiexternals" "$dest_source_root/"
  cp -a -L -- "$source_root/.chezmoidata" "$dest_source_root/"
  [[ -d "$dest_source_root/.chezmoiexternals" && ! -L "$dest_source_root/.chezmoiexternals" ]] ||
    fail "fixture $name did not get a private copy of .chezmoiexternals"
  [[ -d "$dest_source_root/.chezmoidata" && ! -L "$dest_source_root/.chezmoidata" ]] ||
    fail "fixture $name did not get a private copy of .chezmoidata"
  printf '%s\n' "$dest"
}

# Replace an exact block in one external template. The literal must be present,
# so a case cannot quietly stop testing anything when the template is reworded.
edit_external() {
  local tree=$1 file=$2 old=$3 new=$4
  local tree_source
  tree_source=$(resolve_source_root "$tree")
  python3 -c '
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
if old not in text:
    sys.exit(f"fixture literal not found in {path}:\n{old}")
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new, 1))
' "$tree_source/.chezmoiexternals/$file" "$old" "$new"
}

expect_reject() {
  local tree=$1 label=$2 want=$3 report="$scratch/report"
  if bash "$gate" "$tree" >"$report" 2>&1; then
    fail "$label was accepted; the gate does not detect it: $(tr '\n' ';' <"$report")"
  fi
  grep -qF -- "$want" "$report" ||
    fail "$label was rejected for the wrong reason: $(tr '\n' ';' <"$report")"
  pass "$label"
}

bash "$gate" "$repo_root" >/dev/null 2>&1 ||
  fail 'the unmodified tree should pass before anything is mutated'
pass 'the unmodified tree passes'

# 1. The checksum table disappears.
missing=$(fixture missing-table)
edit_external "$missing" vcs.toml "
[gh.checksum]
sha256 = '{{ includeTemplate \"release-lock-ref.tmpl\" (dict \"ctx\" . \"tool\" \"gh\" \"field\" \"sha256\" \"platform\" \"auto\") }}'" ''
expect_reject "$missing" 'a stanza whose checksum table is removed is rejected, naming the tool' \
  '[gh] on linux-amd64 (lock gh [linux-amd64]): downloads a lock artifact that has a digest but declares no [gh.checksum] table'

# 2. The digest is well-formed hex, and wrong. This is the case a shape-only
#    check accepts: it renders fine and only breaks at apply time.
wrong=$(fixture wrong-digest)
edit_external "$wrong" dev-tools.toml \
  "[ast-grep.checksum]
sha256 = '{{ \$astGrepArchiveSha256 }}'" \
  "[ast-grep.checksum]
sha256 = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'"
expect_reject "$wrong" 'a well-formed but wrong digest is rejected' \
  '[ast-grep.checksum] does not match the lock -- sha256 declared ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff but the lock records '

# 3. The url drifts off the lock, so URL membership alone would stop demanding a
#    checksum at all. The table is dropped with it, exactly as a drifting change
#    would: the point is that nothing fails without the coverage floor.
drifted=$(fixture drifted-url)
edit_external "$drifted" dev-tools.toml \
  "[buf]
type = \"archive-file\"
url = '{{ \$bufArchiveUrl }}'" \
  "[buf]
type = \"archive-file\"
url = 'https://buf.example.invalid/dist/v1.72.0/buf-{{ .chezmoi.os }}-{{ .chezmoi.arch }}.tar.gz'"
edit_external "$drifted" dev-tools.toml "
[buf.checksum]
sha256 = '{{ \$bufArchiveSha256 }}'" ''
expect_reject "$drifted" 'a stanza that drifts off the lock url is rejected' \
  '[buf] on linux-amd64: expected to download a digested lock artifact, but no stanza of that name matched one'
grep -qF 'EXPECTED_LOCK_BACKED' "$scratch/report" ||
  fail 'the drift rejection should tell a maintainer where to record a legitimate removal'
pass 'the drift rejection names the list a legitimate removal is edited out of'

# 4/5. The acceptance corners, asserted against the same renders the gate reads
#      rather than against the templates.
render_dir="$scratch/rendered"
mkdir -p -- "$render_dir" "$scratch/bin" "$scratch/home" "$scratch/target"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf '[data]\n' >"$scratch/empty.toml"

render_leg() {
  local os=$1 arch=$2 ext name
  for ext in "$source_root/.chezmoiexternals"/*.toml; do
    name=$(basename -- "$ext" .toml)
    printf '{{- $_ := set .chezmoi "arch" "%s" -}}\n' "$arch" >"$scratch/external.tmpl"
    cat "$ext" >>"$scratch/external.tmpl"
    render "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$scratch/external.tmpl" "$render_dir/$os-$arch--$name.toml" ||
      fail "render failed: .chezmoiexternals/$name.toml on $os-$arch"
  done
}
render_leg linux amd64
render_leg darwin arm64

python3 -c '
import json
import pathlib
import sys

render_dir, lock_path = pathlib.Path(sys.argv[1]), sys.argv[2]
import tomllib

with open(lock_path, encoding="utf-8") as handle:
    tools = json.load(handle)["releases"]["tools"]

stanzas = {}
for rendered in sorted(render_dir.glob("*.toml")):
    leg = rendered.name.split("--", 1)[0]
    document = tomllib.loads(rendered.read_text(encoding="utf-8"))
    for name, stanza in document.items():
        if isinstance(stanza, dict):
            stanzas.setdefault(leg, {})[name] = stanza

problems = []

# The version-only exemptions: present in the render, no checksum table, and no
# lock artifacts for the tool that could have supplied one.
version_only = {
    "linux-amd64": {
        "kubectl": "kubectl",
        "kubectl-convert": "kubectl",
        "helm": "helm",
        "glab": "glab",
        "winbox": "winbox",
        "winbox-icon": "winbox",
    },
    "darwin-arm64": {
        "kubectl": "kubectl",
        "kubectl-convert": "kubectl",
        "helm": "helm",
        "glab": "glab",
        "winbox": "winbox",
    },
}
for leg, expected in version_only.items():
    for name, tool in expected.items():
        stanza = stanzas.get(leg, {}).get(name)
        if stanza is None:
            problems.append(f"{leg}: expected a [{name}] stanza in the render")
            continue
        if "checksum" in stanza:
            problems.append(f"{leg}: [{name}] unexpectedly declares a checksum table")
        if tools[tool].get("artifacts"):
            problems.append(
                f"{tool} now records lock artifacts; it is no longer a "
                "version-only exemption and this case must be updated"
            )

if "agy" in tools or "agy" in stanzas["linux-amd64"]:
    problems.append("retired agy remains managed")

for problem in problems:
    print(problem)
sys.exit(1 if problems else 0)
' "$render_dir" "$source_root/.chezmoidata/releases.json" ||
  fail 'the exemption corners no longer hold (listed above)'
pass 'the version-only externals pass with no checksum table'
pass 'retired agy is absent from lock and externals'

printf 'test-check-external-checksum-coverage: ok\n'
