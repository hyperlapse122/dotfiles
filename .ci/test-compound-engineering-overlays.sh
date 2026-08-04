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
#   - a foreign symlink at the reference path is reclaimed, not written through
#   - a foreign symlink in the archive-owned directory chain is refused
#   - the CE external is additive (exact removed from the localArchive block)
#   - the persona content contract holds (glab, item-schema, confidential->sensitive,
#     degrade sentences, single-label tool guidance; no gh / MR listing)
#
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
  < "$root/.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.sh.tmpl" \
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
# The run_after_ name is load-bearing: the destination sits in a deliberately
# additive, third-party-writable tree, so the reference has to be re-asserted on
# every apply. A fingerprinted onchange run records a clean skip and would never
# repair live drift such as a foreign symlink at the reference path.
case "$root/.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.sh.tmpl" in
  *"/run_onchange_"*) echo "overlay provisioner must retry on every apply" >&2; exit 1 ;;
  *"/run_after_"*) ;;
  *) echo "overlay provisioner must use the run_after_ lifecycle" >&2; exit 1 ;;
esac

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

# --- foreign symlink at the reference path: reclaim it, never write through it ---
# Agents wire a project-local ce-sweep source into this shared tree. Copying
# through the link would overwrite a tracked file in that checkout, and the
# escaping links must also fail any later source-tree validation.
build_fake_ce
foreign="$scratch/foreign-checkout/.compound-engineering/ce-sweep/sources"
mkdir -p "$foreign"
printf 'project-local persona\n' > "$foreign/gitlab-issues.md"
cp "$foreign/gitlab-issues.md" "$scratch/expected-foreign.md"
ln -sfn "$foreign/gitlab-issues.md" "$current/skills/ce-sweep/references/sources/gitlab-issues.md"
env HOME="$home" bash "$prov"
[ ! -L "$current/skills/ce-sweep/references/sources/gitlab-issues.md" ] \
  || { echo "foreign symlink survived the provisioner" >&2; exit 1; }
cmp -s "$overlays/skills/ce-sweep/references/sources/gitlab-issues.md" \
  "$current/skills/ce-sweep/references/sources/gitlab-issues.md" \
  || { echo "persona not reinstalled over the foreign symlink" >&2; exit 1; }
cmp -s "$scratch/expected-foreign.md" "$foreign/gitlab-issues.md" \
  || { echo "provisioner wrote through the foreign symlink" >&2; exit 1; }

# --- foreign symlink in the archive-owned directory chain: refuse, do not delete ---
build_fake_ce
foreign_dir="$scratch/foreign-sources"
mkdir -p "$foreign_dir"
printf 'outside\n' > "$foreign_dir/keep.md"
rm -rf "$current/skills/ce-sweep/references/sources"
ln -sfn "$foreign_dir" "$current/skills/ce-sweep/references/sources"
if env HOME="$home" bash "$prov" 2>"$scratch/chain.err"; then
  echo "provisioner accepted a symlinked directory component" >&2; exit 1
fi
grep -q 'is not a plain directory' "$scratch/chain.err" \
  || { echo "directory-chain conflict not reported" >&2; exit 1; }
[ -L "$current/skills/ce-sweep/references/sources" ] \
  || { echo "provisioner deleted an archive-owned directory component" >&2; exit 1; }
[ ! -e "$foreign_dir/gitlab-issues.md" ] \
  || { echo "provisioner wrote through the symlinked directory" >&2; exit 1; }
cmp -s "$foreign_dir/keep.md" <(printf 'outside\n') \
  || { echo "provisioner disturbed the symlinked directory contents" >&2; exit 1; }

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

# --- Windows PowerShell halves ------------------------------------------------
# The overlay install and the sibling-version prune have Windows counterparts
# behind `eq windows` render guards. pwsh runs the same .NET file APIs on every
# OS, so the rendered scripts execute here against a scratch HOME and prove the
# same contracts as the POSIX runs above: inject + merge + byte-identical,
# second-run convergence, foreign-link reclaim, chain refusal, and prune
# boundaries (stale removed, current kept, reparse points and stray files
# preserved, missing current a no-op).
command -v pwsh >/dev/null 2>&1 || {
  echo "pwsh is required for the Windows overlay/prune checks" >&2; exit 1;
}

prov_ps1="$scratch/provisioner.ps1"
prune_ps1="$scratch/prune.ps1"
win_override='{"chezmoi":{"os":"windows","arch":"amd64"}}'
env PATH="$bin:$PATH" chezmoi \
  --config "$scratch/empty.toml" \
  --source "$root" \
  --override-data "$win_override" \
  execute-template \
  < "$root/.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.ps1.tmpl" \
  > "$prov_ps1"
env PATH="$bin:$PATH" chezmoi \
  --config "$scratch/empty.toml" \
  --source "$root" \
  --override-data "$win_override" \
  execute-template \
  < "$root/.chezmoiscripts/00-tools/run_onchange_after_compound-engineering.ps1.tmpl" \
  > "$prune_ps1"

ps1_version=$(grep -oE "Join-Path \\\$baseDir 'v[0-9][0-9.]+'" "$prov_ps1" | grep -oE 'v[0-9][0-9.]+')
[ -n "$ps1_version" ] || { echo "could not resolve CE version from rendered ps1" >&2; exit 1; }
[ "$ps1_version" = "$version" ] \
  || { echo "POSIX and Windows halves pin different CE versions ($version vs $ps1_version)" >&2; exit 1; }

run_ps1() { env HOME="$home" pwsh -NoProfile -File "$1"; }

# --- happy path: inject + merge + byte-identical, then second-run convergence ---
build_fake_ce
run_ps1 "$prov_ps1"
cmp -s "$overlays/skills/ce-sweep/references/sources/gitlab-issues.md" "$src" \
  || { echo "ps1: injected persona differs from overlay source" >&2; exit 1; }
cmp -s "$root/.ci/fixtures/ce-sweep/SKILL.md" "$skill" \
  || { echo "ps1: ce-sweep skill changed on first run" >&2; exit 1; }
cp "$src" "$scratch/persona-after-first.md"
run_ps1 "$prov_ps1"
cmp -s "$scratch/persona-after-first.md" "$src" \
  || { echo "ps1: persona changed on second run" >&2; exit 1; }
cmp -s "$root/.ci/fixtures/ce-sweep/SKILL.md" "$skill" \
  || { echo "ps1: ce-sweep skill changed on second run" >&2; exit 1; }

# --- skip when overlays dir absent / CE version dir absent ---
build_fake_ce
rm -rf "$overlays"
run_ps1 "$prov_ps1"
[ ! -e "$current/skills/ce-sweep/references/sources/gitlab-issues.md" ] \
  || { echo "ps1: persona created when overlay source was absent" >&2; exit 1; }
build_fake_ce
rm -rf "$current"
run_ps1 "$prov_ps1"
[ ! -e "$current" ] || { echo "ps1: CE version dir recreated when absent" >&2; exit 1; }

# --- foreign link at the reference path: reclaim it, never write through it ---
build_fake_ce
mkdir -p "$foreign"
ln -sfn "$foreign/gitlab-issues.md" "$current/skills/ce-sweep/references/sources/gitlab-issues.md"
run_ps1 "$prov_ps1" 2>"$scratch/ps1-reclaim.err"
[ ! -L "$current/skills/ce-sweep/references/sources/gitlab-issues.md" ] \
  || { echo "ps1: foreign symlink survived the provisioner" >&2; exit 1; }
cmp -s "$overlays/skills/ce-sweep/references/sources/gitlab-issues.md" \
  "$current/skills/ce-sweep/references/sources/gitlab-issues.md" \
  || { echo "ps1: persona not reinstalled over the foreign symlink" >&2; exit 1; }
cmp -s "$scratch/expected-foreign.md" "$foreign/gitlab-issues.md" \
  || { echo "ps1: provisioner wrote through the foreign symlink" >&2; exit 1; }
grep -q 'replaced foreign link' "$scratch/ps1-reclaim.err" \
  || { echo "ps1: foreign-link reclaim not reported" >&2; exit 1; }

# --- foreign symlink in the archive-owned directory chain: refuse, do not delete ---
build_fake_ce
rm -rf "$current/skills/ce-sweep/references/sources"
ln -sfn "$foreign_dir" "$current/skills/ce-sweep/references/sources"
if run_ps1 "$prov_ps1" 2>"$scratch/ps1-chain.err"; then
  echo "ps1: provisioner accepted a symlinked directory component" >&2; exit 1
fi
grep -q 'is not a plain directory' "$scratch/ps1-chain.err" \
  || { echo "ps1: directory-chain conflict not reported" >&2; exit 1; }
[ -L "$current/skills/ce-sweep/references/sources" ] \
  || { echo "ps1: provisioner deleted an archive-owned directory component" >&2; exit 1; }
[ ! -e "$foreign_dir/gitlab-issues.md" ] \
  || { echo "ps1: provisioner wrote through the symlinked directory" >&2; exit 1; }
cmp -s "$foreign_dir/keep.md" <(printf 'outside\n') \
  || { echo "ps1: provisioner disturbed the symlinked directory contents" >&2; exit 1; }

# --- prune: stale version removed, current kept, reparse points and stray
#     files preserved (undeclared state), missing current a no-op ---
build_fake_ce
stale="$ce_base/v0.0.0-stale"
mkdir -p "$stale/skills"
printf 'stale\n' > "$stale/skills/keep.md"
stray="$ce_base/notes.txt"
printf 'stray\n' > "$stray"
linked_dir="$scratch/linked-version"
mkdir -p "$linked_dir"
ln -sfn "$linked_dir" "$ce_base/v9.9.9-link"
run_ps1 "$prune_ps1" >"$scratch/ps1-prune.err" 2>&1
[ ! -e "$stale" ] || { echo "ps1: prune kept a stale version dir" >&2; exit 1; }
[ -d "$current" ] || { echo "ps1: prune removed the current version" >&2; exit 1; }
[ -L "$ce_base/v9.9.9-link" ] || { echo "ps1: prune removed an undeclared reparse point" >&2; exit 1; }
[ -f "$stray" ] || { echo "ps1: prune removed an undeclared stray file" >&2; exit 1; }
grep -q 'preserved reparse point' "$scratch/ps1-prune.err" \
  || { echo "ps1: reparse-point preservation not reported" >&2; exit 1; }
# Second run converges to a no-op.
run_ps1 "$prune_ps1"
[ -d "$current" ] || { echo "ps1: second prune removed the current version" >&2; exit 1; }
[ -L "$ce_base/v9.9.9-link" ] || { echo "ps1: second prune removed the reparse point" >&2; exit 1; }
# Missing current version: defensive no-op (never nukes the tree).
rm -rf "$current"
run_ps1 "$prune_ps1"
[ -L "$ce_base/v9.9.9-link" ] || { echo "ps1: prune without current removed the reparse point" >&2; exit 1; }
[ -f "$stray" ] || { echo "ps1: prune without current removed the stray file" >&2; exit 1; }

echo "compound-engineering overlays: ok"
