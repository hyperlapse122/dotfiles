#!/usr/bin/env bash
# Isolated, network-free verification of the compound-engineering overlays mechanism.
#
# Renders the overlay provisioner via `chezmoi execute-template` (stub op, empty
# config, --source PWD), points HOME at a scratch tree so the provisioner's resolved
# CE version dir lands on a fake CE checkout, runs it, and asserts:
#   - the persona is injected at the right CE-relative path
#   - archive-owned ce-sweep files remain byte-identical across repeated runs
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
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/ce-overlays.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

# --- stub op + empty config so execute-template never hits live 1Password ---
bin="$scratch/bin"
mkdir -p "$bin"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$bin/op"
chmod 700 "$bin/op"
: > "$scratch/empty.toml"

# --- render the provisioner and external manifest ---
prov="$scratch/provisioner.sh"
rendered_externals="$scratch/ai-agents.toml"
env PATH="$bin:$PATH" chezmoi \
  --config "$scratch/empty.toml" \
  --source "$root" \
  execute-template \
  < "$root/.chezmoiscripts/00-tools/run_onchange_after_compound-engineering-overlays.sh.tmpl" \
  > "$prov"
env PATH="$bin:$PATH" chezmoi \
  --config "$scratch/empty.toml" \
  --source "$root" \
  execute-template \
  < "$root/.chezmoiexternals/ai-agents.toml" \
  > "$rendered_externals"

# The rendered script resolves CURRENT="$BASE_DIR/v<semver>" with BASE_DIR under $HOME.
# Point HOME at a scratch tree and build the matching structure there.
home="$scratch/home"
version=$(grep -oE 'CURRENT="\$BASE_DIR/[^"]+"' "$prov" | sed -E 's|.*/(v[0-9][0-9.]+)"$|\1|')
[ -n "$version" ] || { echo "could not resolve CE version from rendered script" >&2; exit 1; }
# The onchange name and source fingerprint are load-bearing. The additive
# external preserves the installed reference between no-change applies.
case "$root/.chezmoiscripts/00-tools/run_onchange_after_compound-engineering-overlays.sh.tmpl" in
  *"/run_onchange_after_"*) ;;
  *) echo "overlay provisioner must use onchange lifecycle" >&2; exit 1 ;;
esac
fingerprint_path='dot_local/share/compound-engineering-overlays/skills/ce-sweep/references/sources/gitlab-issues.md'
fingerprint_digest=$(sha256sum "$root/$fingerprint_path" | cut -d ' ' -f 1)
grep -qF "$fingerprint_path  $fingerprint_digest" "$prov" \
  || { echo "overlay provisioner fingerprint missing managed reference" >&2; exit 1; }

ce_base="$home/.local/share/compound-engineering"
overlays="$home/.local/share/compound-engineering-overlays"
current="$ce_base/$version"

build_fake_ce() {
  rm -rf "$home"
  mkdir -p "$current/skills/ce-sweep/references/sources"
  cp "$root/.ci/fixtures/ce-sweep/SKILL.md" "$current/skills/ce-sweep/SKILL.md"
  for f in email github-issues slack; do
    printf 'upstream %s\n' "$f" > "$current/skills/ce-sweep/references/sources/$f.md"
    cp "$current/skills/ce-sweep/references/sources/$f.md" "$scratch/expected-$f.md"
  done
  mkdir -p "$overlays"
  cp -Rp "$root/dot_local/share/compound-engineering-overlays/." "$overlays/"
}

# --- happy path: inject + merge + byte-identical ---
build_fake_ce
env HOME="$home" bash "$prov"

src="$current/skills/ce-sweep/references/sources/gitlab-issues.md"
skill="$current/skills/ce-sweep/SKILL.md"
[ -f "$src" ] || { echo "persona not injected" >&2; exit 1; }
[ -f "$skill" ] || { echo "ce-sweep skill missing" >&2; exit 1; }
cmp -s "$root/.ci/fixtures/ce-sweep/SKILL.md" "$skill" \
  || { echo "ce-sweep skill changed on first run" >&2; exit 1; }
for f in email github-issues slack; do
  cmp -s "$scratch/expected-$f.md" "$current/skills/ce-sweep/references/sources/$f.md" \
    || { echo "upstream $f.md changed on first run" >&2; exit 1; }
done
cmp -s "$overlays/skills/ce-sweep/references/sources/gitlab-issues.md" "$src" \
  || { echo "injected persona differs from overlay source" >&2; exit 1; }

# A later archive reconciliation restores archive-owned files. The provisioner
# must reinstall only the reference and leave every archive-owned file unchanged.
cp "$root/.ci/fixtures/ce-sweep/SKILL.md" "$skill"
env HOME="$home" bash "$prov"
cmp -s "$root/.ci/fixtures/ce-sweep/SKILL.md" "$skill" \
  || { echo "ce-sweep skill changed on second run" >&2; exit 1; }
cmp -s "$overlays/skills/ce-sweep/references/sources/gitlab-issues.md" "$src" \
  || { echo "persona differs after second run" >&2; exit 1; }
for f in email github-issues slack; do
  cmp -s "$scratch/expected-$f.md" "$current/skills/ce-sweep/references/sources/$f.md" \
    || { echo "upstream $f.md changed on second run" >&2; exit 1; }
done

# --- skip when overlays dir absent (leave CE tree intact) ---
build_fake_ce
rm -rf "$overlays"
env HOME="$home" bash "$prov"
cmp -s "$root/.ci/fixtures/ce-sweep/SKILL.md" "$current/skills/ce-sweep/SKILL.md" \
  || { echo "ce-sweep skill changed when overlay source was absent" >&2; exit 1; }
[ ! -e "$current/skills/ce-sweep/references/sources/gitlab-issues.md" ] \
  || { echo "persona created when overlay source was absent" >&2; exit 1; }
for f in email github-issues slack; do
  cmp -s "$scratch/expected-$f.md" "$current/skills/ce-sweep/references/sources/$f.md" \
    || { echo "upstream $f.md changed when overlay source was absent" >&2; exit 1; }
done

# --- skip when CE version dir absent ---
build_fake_ce
rm -rf "$current"
env HOME="$home" bash "$prov"   # exits 0
[ ! -e "$current" ] || { echo "CE version dir recreated when absent" >&2; exit 1; }

# --- CE external is additive: inspect its rendered table, not template source ---
ce_block=$(awk '
  /^\["\.local\/share\/compound-engineering\/v/ { in_ce=1; first=1 }
  in_ce && !first && /^\[/ { exit }
  in_ce { print; first=0 }
' "$rendered_externals")
printf '%s\n' "$ce_block" | grep -q '^type = "archive"$' \
  || { echo "rendered CE external block missing" >&2; exit 1; }
if printf '%s\n' "$ce_block" | grep -q '^exact = true$'; then
  echo "rendered CE external is not additive" >&2; exit 1
fi
grep -q '^exact = true$' "$rendered_externals" \
  || { echo "agent-skills exact archives unexpectedly changed" >&2; exit 1; }

# --- persona content contract ---
persona="$root/dot_local/share/compound-engineering-overlays/skills/ce-sweep/references/sources/gitlab-issues.md"
contract() { grep -qF -- "$1" "$persona" || { echo "persona missing: $1" >&2; exit 1; }; }
contract 'glab'
contract 'group/project#<iid>'
contract 'confidential'
contract 'sensitive: true'
contract 'GitLab tools unavailable — source skipped this run.'
contract 'GitLab write capability unavailable — source degrades to read-only ingest; items will be marked ack_deferred.'
contract 'glab issue update <iid> --repo <group/project> --label <configured-label>'
contract '--order updated_at --sort desc --output json --page <n> --per-page 100'
contract 'updated_at >= cursor'
contract 'members/all/<author-id>'
contract 'Confidential GitLab issue group/project#<iid>'
contract 'Fetch is all-or-nothing.'
contract 'During fetch, use only `glab` read commands'
contract 'Empty list when none or when the issue is confidential'
# must not lean on gh / GitHub-CLI tooling or fetch merge requests
if grep -qiE '\bgh\b|github-cli' "$persona"; then
  echo "persona references gh/github-cli tooling" >&2; exit 1
fi
if grep -qiE 'glab mr\b|glab mr list|merge request list' "$persona"; then
  echo "persona fetches merge requests" >&2; exit 1
fi

echo "compound-engineering overlays: ok"
