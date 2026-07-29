#!/usr/bin/env bash
# Isolated, network-free verification of the compound-engineering overlays mechanism.
#
# Renders the overlay provisioner via `chezmoi execute-template` (stub op, empty
# config, --source PWD), points HOME at a scratch tree so the provisioner's resolved
# CE version dir lands on a fake CE checkout, runs it, and asserts:
#   - the persona is injected at the right CE-relative path
#   - the three upstream source files are preserved (merge, not replace)
#   - the injected persona is byte-identical to the deployed overlay source
#   - the provisioner exits 0 when the overlays dir or the CE dir is absent
#   - the CE external is additive (exact removed from the localArchive block)
#   - the persona content contract holds (glab, item-schema, confidential->sensitive,
#     degrade sentences, single-label tool guidance; no gh / MR listing)
#
# Modelled on .ci/smoke-agy-plugin-installer.sh and the codex-wrapper ci.yml job.
set -euo pipefail

root=${1:-$(pwd)}
scratch="$(mktemp -d -t ce-overlays.XXXXXX)"
trap 'rm -rf -- "$scratch"' EXIT

# --- stub op + empty config so execute-template never hits live 1Password ---
bin="$scratch/bin"
mkdir -p "$bin"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$bin/op"
chmod 700 "$bin/op"
: > "$scratch/empty.toml"

# --- render the provisioner ---
prov="$scratch/provisioner.sh"
env PATH="$bin:$PATH" chezmoi \
  --config "$scratch/empty.toml" \
  --source "$root" \
  execute-template \
  < "$root/.chezmoiscripts/00-tools/run_onchange_after_compound-engineering-overlays.sh.tmpl" \
  > "$prov"

# The rendered script resolves CURRENT="$BASE_DIR/v<semver>" with BASE_DIR under $HOME.
# Point HOME at a scratch tree and build the matching structure there.
home="$scratch/home"
version=$(grep -oE 'CURRENT="\$BASE_DIR/[^"]+"' "$prov" | sed -E 's|.*/(v[0-9][0-9.]+)"$|\1|')
[ -n "$version" ] || { echo "could not resolve CE version from rendered script" >&2; exit 1; }

ce_base="$home/.local/share/compound-engineering"
overlays="$home/.local/share/compound-engineering-overlays"
current="$ce_base/$version"

build_fake_ce() {
  rm -rf "$home"
  mkdir -p "$current/skills/ce-sweep/references/sources"
  for f in email github-issues slack; do
    printf 'upstream %s\n' "$f" > "$current/skills/ce-sweep/references/sources/$f.md"
  done
  mkdir -p "$overlays/skills/ce-sweep/references/sources"
  cp "$root/dot_local/share/compound-engineering-overlays/skills/ce-sweep/references/sources/gitlab-issues.md" \
     "$overlays/skills/ce-sweep/references/sources/gitlab-issues.md"
}

# --- happy path: inject + merge + byte-identical ---
build_fake_ce
env HOME="$home" bash "$prov"

src="$current/skills/ce-sweep/references/sources/gitlab-issues.md"
[ -f "$src" ] || { echo "persona not injected" >&2; exit 1; }
for f in email github-issues slack; do
  [ -f "$current/skills/ce-sweep/references/sources/$f.md" ] || { echo "upstream $f.md lost in merge" >&2; exit 1; }
done
cmp -s "$overlays/skills/ce-sweep/references/sources/gitlab-issues.md" "$src" \
  || { echo "injected persona differs from overlay source" >&2; exit 1; }

# --- skip when overlays dir absent (leave CE tree intact) ---
build_fake_ce
rm -rf "$overlays"
env HOME="$home" bash "$prov"
[ -f "$current/skills/ce-sweep/references/sources/email.md" ] \
  || { echo "CE tree modified when overlays dir absent" >&2; exit 1; }

# --- skip when CE version dir absent ---
build_fake_ce
rm -rf "$current"
env HOME="$home" bash "$prov"   # exits 0

# --- CE external is additive: exactly one `exact = true` remains (agent-skills block) ---
exact_count=$(grep -c '^exact = true$' "$root/.chezmoiexternals/ai-agents.toml" || true)
[ "$exact_count" -eq 1 ] \
  || { echo "expected exactly one 'exact = true' (agent-skills block); found $exact_count" >&2; exit 1; }

# --- persona content contract ---
persona="$root/dot_local/share/compound-engineering-overlays/skills/ce-sweep/references/sources/gitlab-issues.md"
contract() { grep -qF "$1" "$persona" || { echo "persona missing: $1" >&2; exit 1; }; }
contract 'glab'
contract 'group/project#<iid>'
contract 'confidential'
contract 'sensitive: true'
contract 'GitLab tools unavailable — source skipped this run.'
contract 'GitLab write capability unavailable — source degrades to read-only ingest; items will be marked ack_deferred.'
contract 'glab issue edit <iid> --add-label <configured-label>'
# must not lean on gh / GitHub-CLI tooling or fetch merge requests
if grep -qiE '\bgh\b|github-cli' "$persona"; then
  echo "persona references gh/github-cli tooling" >&2; exit 1
fi
if grep -qiE 'glab mr\b|glab mr list|merge request list' "$persona"; then
  echo "persona fetches merge requests" >&2; exit 1
fi

echo "compound-engineering overlays: ok"
