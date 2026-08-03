#!/usr/bin/env bash
# Isolated, network-free proof of the exact official Figma collection external.
set -euo pipefail

root=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/figma-skills-stage.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'figma staging fixture: %s\n' "$*" >&2; exit 1; }
command -v chezmoi >/dev/null || fail "chezmoi is required"
command -v jq >/dev/null || fail "jq is required"
command -v tar >/dev/null || fail "tar is required"

lock="$root/.chezmoidata/releases.json"
revision=$(jq -er '.releases.tools["figma/mcp-server-guide"].revision | select(test("^[0-9a-f]{40}$"))' "$lock")
skills=()
while IFS= read -r skill; do skills[${#skills[@]}]=$skill; done < <(
  jq -er '.releases.tools["figma/mcp-server-guide"].skills[]' "$lock"
)
((${#skills[@]} > 0)) || fail "locked inventory is empty"

archive_root="$scratch/mcp-server-guide-$revision"
for skill in "${skills[@]}"; do
  mkdir -p "$archive_root/skills/$skill/references" "$archive_root/skills/$skill/assets"
  printf '# %s\n' "$skill" > "$archive_root/skills/$skill/SKILL.md"
  printf 'nested reference for %s\n' "$skill" > "$archive_root/skills/$skill/references/guide.md"
  printf 'supporting asset for %s\n' "$skill" > "$archive_root/skills/$skill/assets/icon.txt"
done
mkdir -p "$archive_root/skills/not-figma" "$archive_root/docs"
printf 'excluded\n' > "$archive_root/skills/not-figma/SKILL.md"
printf 'excluded\n' > "$archive_root/docs/repository.md"
tar -C "$scratch" -czf "$scratch/figma.tar.gz" "$(basename "$archive_root")"

: > "$scratch/empty.toml"
rendered="$scratch/ai-agents.toml"
chezmoi --config "$scratch/empty.toml" --source "$root" execute-template --file \
  "$root/.chezmoiexternals/ai-agents.toml" > "$rendered"

# The canonical accessor must reject every malformed collection shape before
# emitting a revision or inventory that could become runnable TOML.
accessor='{{ includeTemplate "release-lock-ref.tmpl" (dict "ctx" . "tool" "figma/mcp-server-guide" "field" "skillsJson") }}'
valid_override=$(jq -c '{releases:{tools:{"figma/mcp-server-guide":.releases.tools["figma/mcp-server-guide"]}}}' "$lock")
actual=$(chezmoi --config "$scratch/empty.toml" --source "$root" --override-data "$valid_override" execute-template "$accessor")
[[ "$actual" == "$(jq -c '.releases.tools["figma/mcp-server-guide"].skills' "$lock")" ]] ||
  fail "valid inventory did not round-trip through the accessor"

expect_rejected() {
  local label=$1 override=$2 output="$scratch/rejected.out"
  if chezmoi --config "$scratch/empty.toml" --source "$root" --override-data "$override" \
    execute-template "$accessor" >"$output" 2>/dev/null; then
    fail "$label lock unexpectedly rendered"
  fi
  [[ ! -s "$output" ]] || fail "$label lock emitted output before rejection"
}
missing_source="$scratch/missing-source"
mkdir -p "$missing_source/.chezmoitemplates" "$missing_source/.chezmoidata"
cp "$root/.chezmoitemplates/release-lock-ref.tmpl" "$missing_source/.chezmoitemplates/"
printf '{"releases":{"tools":{}}}\n' > "$missing_source/.chezmoidata/releases.json"
if chezmoi --config "$scratch/empty.toml" --source "$missing_source" \
  execute-template "$accessor" >"$scratch/missing.out" 2>/dev/null; then
  fail "missing-entry lock unexpectedly rendered"
fi
[[ ! -s "$scratch/missing.out" ]] || fail "missing-entry lock emitted output before rejection"
expect_rejected wrong-kind "$(jq -c '.releases.tools["figma/mcp-server-guide"].kind="githubRelease"' <<<"$valid_override")"
expect_rejected malformed-revision "$(jq -c '.releases.tools["figma/mcp-server-guide"].revision="main"' <<<"$valid_override")"
expect_rejected empty-inventory "$(jq -c '.releases.tools["figma/mcp-server-guide"].skills=[]' <<<"$valid_override")"
expect_rejected duplicate-inventory "$(jq -c '.releases.tools["figma/mcp-server-guide"].skills=["figma-use","figma-use"]' <<<"$valid_override")"
expect_rejected unsorted-inventory "$(jq -c '.releases.tools["figma/mcp-server-guide"].skills=["figma-use-motion","figma-use"]' <<<"$valid_override")"
expect_rejected unsafe-name "$(jq -c '.releases.tools["figma/mcp-server-guide"].skills=["../figma-use"]' <<<"$valid_override")"
expect_rejected empty-name-segment "$(jq -c '.releases.tools["figma/mcp-server-guide"].skills=["figma-use--guide"]' <<<"$valid_override")"

stanza="$scratch/figma.toml"
sed -n '/^\["\.local\/share\/figma-skills-stage"\]$/,/^$/p' "$rendered" > "$stanza"
grep -q "archive/$revision.tar.gz" "$stanza" || fail "external does not use the locked revision"
grep -q '^exact = true$' "$stanza" || fail "external is not exact"
grep -q '^stripComponents = 2$' "$stanza" || fail "external has the wrong archive root stripping"
archive_url="file://$scratch/figma.tar.gz"
grep -qE 'gitHubLatest|gitHubRelease|gitHubTag|curl|wget' "$stanza" &&
  fail "Figma external performs a render-time network lookup"
sed -i.bak "s|^url = .*|url = '$archive_url'|" "$stanza"
rm -f "$stanza.bak"

source_dir="$scratch/source"
dest="$scratch/home"
mkdir -p "$source_dir/.chezmoiexternals" "$dest/.local/share/figma-skills-stage/stale/nested"
printf 'staging residue\n' > "$dest/.local/share/figma-skills-stage/stale/nested/file.txt"
cp "$stanza" "$source_dir/.chezmoiexternals/figma.toml"
chezmoi --config "$scratch/empty.toml" --source "$source_dir" --destination "$dest" \
  --cache "$scratch/cache" --persistent-state "$scratch/state.boltdb" apply

stage="$dest/.local/share/figma-skills-stage"
[[ ! -e "$stage/stale" ]] || fail "exact materialization retained staging residue"
[[ ! -e "$stage/not-figma" && ! -e "$stage/docs" ]] || fail "unrelated archive content was staged"
for skill in "${skills[@]}"; do
  [[ -f "$stage/$skill/SKILL.md" ]] || fail "missing $skill/SKILL.md"
  [[ -f "$stage/$skill/references/guide.md" ]] || fail "missing nested reference for $skill"
  [[ -f "$stage/$skill/assets/icon.txt" ]] || fail "missing supporting asset for $skill"
done
staged=()
while IFS= read -r skill; do staged[${#staged[@]}]=$skill; done < <(
  for path in "$stage"/*; do [[ -d "$path" ]] && basename "$path"; done | LC_ALL=C sort
)
[[ "$(printf '%s\n' "${staged[@]}")" == "$(printf '%s\n' "${skills[@]}")" ]] ||
  fail "staged direct children differ from the locked inventory"

printf 'figma skills POSIX staging fixture passed (%s skills)\n' "${#skills[@]}"
