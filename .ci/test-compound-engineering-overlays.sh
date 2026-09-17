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
#   - the CE external excludes */skills/ce-sweep/references/interview.md (prevents chezmoi drift warnings on apply)
#   - the upstream root plugin.json survives the overlay run (agy needs it as its bundle manifest)
#   - the agent skill externals are exact (no overlay to preserve)
#   - the persona content contract holds (glab, item-schema, confidential->sensitive,
#     degrade sentences, single-label tool guidance; no gh / MR listing)
#   - the CLI elevation adapter overlay (ce-plan and ce-brainstorm) differs from the
#     recorded upstream digest on only the effort line, and the two overlay copies
#     are byte-identical
#   - a guarded elevation adapter is replaced only while the archive copy still
#     matches the recorded upstream digest; a mismatching copy is left unchanged
#     with a warning naming the file, and a second apply after install writes nothing
#   - the digest check is portable: it installs through a macOS-style `shasum -a 256`
#     when `sha256sum` is absent, and with neither tool on PATH it warns, leaves the
#     guarded entries unchanged, and still exits 0 rather than aborting the apply
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
prune="$scratch/prune.sh"
env PATH="$bin:$PATH" chezmoi \
  --config "$scratch/empty.toml" \
  --source "$root" \
  execute-template \
  < "$root/.chezmoiscripts/70-agents/run_onchange_after_zz-prune-agent-marketplace-archives.sh.tmpl" \
  > "$prune"

# The rendered script resolves CURRENT="$BASE_DIR/v<semver>" with BASE_DIR under $HOME.
# Point HOME at a scratch tree and build the matching structure there.
home="$scratch/home"
version=$(grep -oE '"\$HOME/\.local/share/compound-engineering/v[0-9][0-9.]*"' "$prov" | sed -E 's|.*/(v[0-9][0-9.]+)"$|\1|' | head -1)
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
# omp's own copy of the same archive. It carries no root plugin.json, because
# that file makes omp misclassify the tree and drop 30 of 33 skills (cb30ed4),
# while agy needs it present in the copy above. The provisioner must overlay
# both copies, or omp gets a ce-sweep whose references are missing.
omp_current="$home/.local/share/compound-engineering-omp/$version"

build_fake_ce() {
  rm -rf "$home"
  mkdir -p "$current/skills/ce-sweep/references/sources"
  cp "$root/.ci/fixtures/ce-sweep/SKILL.md" "$current/skills/ce-sweep/SKILL.md"
  printf '{"name":"compound-engineering"}\n' > "$current/plugin.json"
  printf 'upstream interview\n' > "$current/skills/ce-sweep/references/interview.md"
  cp "$current/skills/ce-sweep/references/interview.md" "$scratch/expected-interview.md"
  for f in email github-issues slack; do
    printf 'upstream %s\n' "$f" > "$current/skills/ce-sweep/references/sources/$f.md"
    cp "$current/skills/ce-sweep/references/sources/$f.md" "$scratch/expected-$f.md"
  done
  mkdir -p "$omp_current/skills/ce-sweep/references/sources"
  cp "$root/.ci/fixtures/ce-sweep/SKILL.md" "$omp_current/skills/ce-sweep/SKILL.md"
  mkdir -p "$overlays"
  cp -Rp "$root/dot_local/share/compound-engineering-overlays/." "$overlays/"
  # Mirror chezmoi's own source-name convention: an `executable_` prefix marks
  # the target executable and is stripped from the deployed name. The raw `cp`
  # above does not know that convention, so replicate it here.
  while IFS= read -r -d '' source_file; do
    mv -- "$source_file" "$(dirname -- "$source_file")/${source_file##*/executable_}"
  done < <(find "$overlays" -name 'executable_*' -print0)
}

# --- happy path: inject + merge + byte-identical ---
build_fake_ce
env HOME="$home" bash "$prov"

src="$current/skills/ce-sweep/references/sources/gitlab-issues.md"
interview="$current/skills/ce-sweep/references/interview.md"
skill="$current/skills/ce-sweep/SKILL.md"
[ -f "$src" ] || { echo "persona not injected" >&2; exit 1; }
[ -f "$interview" ] || { echo "interview not injected" >&2; exit 1; }
[ -f "$skill" ] || { echo "ce-sweep skill missing" >&2; exit 1; }
cmp -s "$root/.ci/fixtures/ce-sweep/SKILL.md" "$skill" \
  || { echo "ce-sweep skill changed on first run" >&2; exit 1; }
[ -e "$current/plugin.json" ] || { echo "root plugin.json missing after first run" >&2; exit 1; }
for f in email github-issues slack; do
  cmp -s "$scratch/expected-$f.md" "$current/skills/ce-sweep/references/sources/$f.md" \
    || { echo "upstream $f.md changed on first run" >&2; exit 1; }
done
cmp -s "$overlays/skills/ce-sweep/references/sources/gitlab-issues.md" "$src" \
  || { echo "injected persona differs from overlay source" >&2; exit 1; }
cmp -s "$overlays/skills/ce-sweep/references/interview.md" "$interview" \
  || { echo "injected interview differs from overlay source" >&2; exit 1; }
# The omp copy is overlaid too, and it never gains a root plugin.json.
cmp -s "$overlays/skills/ce-sweep/references/sources/gitlab-issues.md" \
  "$omp_current/skills/ce-sweep/references/sources/gitlab-issues.md" \
  || { echo "persona not injected into the omp archive copy" >&2; exit 1; }
cmp -s "$overlays/skills/ce-sweep/references/interview.md" \
  "$omp_current/skills/ce-sweep/references/interview.md" \
  || { echo "interview not injected into the omp archive copy" >&2; exit 1; }
[ ! -e "$omp_current/plugin.json" ] \
  || { echo "omp archive copy gained a root plugin.json" >&2; exit 1; }
# A later archive reconciliation restores archive-owned files. The provisioner
# must reinstall only the reference and leave every archive-owned file unchanged.
cp "$root/.ci/fixtures/ce-sweep/SKILL.md" "$skill"
env HOME="$home" bash "$prov"
cmp -s "$root/.ci/fixtures/ce-sweep/SKILL.md" "$skill" \
  || { echo "ce-sweep skill changed on second run" >&2; exit 1; }
cmp -s "$overlays/skills/ce-sweep/references/sources/gitlab-issues.md" "$src" \
  || { echo "persona differs after second run" >&2; exit 1; }
cmp -s "$overlays/skills/ce-sweep/references/interview.md" "$interview" \
  || { echo "interview differs after second run" >&2; exit 1; }
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
cmp -s "$scratch/expected-interview.md" "$current/skills/ce-sweep/references/interview.md" \
  || { echo "upstream interview.md changed when overlay source was absent" >&2; exit 1; }
for f in email github-issues slack; do
  cmp -s "$scratch/expected-$f.md" "$current/skills/ce-sweep/references/sources/$f.md" \
    || { echo "upstream $f.md changed when overlay source was absent" >&2; exit 1; }
done
# --- skip when CE version dir absent ---
build_fake_ce
rm -rf "$current"
env HOME="$home" bash "$prov"
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

# --- CLI elevation adapter overlay: checksum-guarded whole-file replacement (KTD7) ---
ce_plan_overlay="$root/dot_local/share/compound-engineering-overlays/skills/ce-plan/scripts/executable_elevation-dispatch.sh"
ce_brainstorm_overlay="$root/dot_local/share/compound-engineering-overlays/skills/ce-brainstorm/scripts/executable_elevation-dispatch.sh"
[ -f "$ce_plan_overlay" ] || { echo "ce-plan elevation overlay missing: $ce_plan_overlay" >&2; exit 1; }
[ -f "$ce_brainstorm_overlay" ] || { echo "ce-brainstorm elevation overlay missing: $ce_brainstorm_overlay" >&2; exit 1; }
[ -x "$ce_plan_overlay" ] || { echo "ce-plan elevation overlay is not executable" >&2; exit 1; }
[ -x "$ce_brainstorm_overlay" ] || { echo "ce-brainstorm elevation overlay is not executable" >&2; exit 1; }
cmp -s "$ce_plan_overlay" "$ce_brainstorm_overlay" \
  || { echo "the two elevation overlay files are not byte-identical" >&2; exit 1; }

guarded_sha=$(grep -oE 'GUARDED_UPSTREAM_SHA256="[0-9a-f]{64}"' "$prov" | grep -oE '[0-9a-f]{64}')
[ -n "$guarded_sha" ] || { echo "could not resolve GUARDED_UPSTREAM_SHA256 from rendered script" >&2; exit 1; }

# Reconstruct the pinned upstream script from the overlay alone (no archive needed)
# and prove the recorded digest still matches it.
reconstructed_upstream="$scratch/elevation-dispatch.upstream.sh"
sed 's/^EFFORT="max".*/EFFORT="high"   # settled: elevation runs at high effort/' \
  "$ce_plan_overlay" > "$reconstructed_upstream"
reconstructed_sha=$(sha256sum "$reconstructed_upstream" | cut -d' ' -f1)
[ "$reconstructed_sha" = "$guarded_sha" ] \
  || { echo "recorded upstream digest $guarded_sha does not match the reconstructed upstream $reconstructed_sha" >&2; exit 1; }
diff_line_count=$(diff "$reconstructed_upstream" "$ce_plan_overlay" | grep -c '^[<>]' || true)
[ "$diff_line_count" = "2" ] \
  || { echo "overlay differs from reconstructed upstream on more than the effort line" >&2; exit 1; }

# Fixture archive script equals the pinned upstream digest: apply installs the overlay.
install_upstream_elevation_adapters() {
  mkdir -p "$current/skills/ce-plan/scripts" "$current/skills/ce-brainstorm/scripts" \
    "$omp_current/skills/ce-plan/scripts" "$omp_current/skills/ce-brainstorm/scripts"
  install -m 755 "$reconstructed_upstream" "$current/skills/ce-plan/scripts/elevation-dispatch.sh"
  install -m 755 "$reconstructed_upstream" "$current/skills/ce-brainstorm/scripts/elevation-dispatch.sh"
  install -m 755 "$reconstructed_upstream" "$omp_current/skills/ce-plan/scripts/elevation-dispatch.sh"
  install -m 755 "$reconstructed_upstream" "$omp_current/skills/ce-brainstorm/scripts/elevation-dispatch.sh"
}

build_fake_ce
install_upstream_elevation_adapters
env HOME="$home" bash "$prov"

for dir in "$current" "$omp_current"; do
  for skill in ce-plan ce-brainstorm; do
    installed="$dir/skills/$skill/scripts/elevation-dispatch.sh"
    [ -f "$installed" ] || { echo "elevation adapter not installed: $installed" >&2; exit 1; }
    cmp -s "$ce_plan_overlay" "$installed" \
      || { echo "installed elevation adapter differs from the overlay: $installed" >&2; exit 1; }
    grep -qx 'EFFORT="max"   # this repository raises elevation to max effort' "$installed" \
      || { echo "installed elevation adapter does not assign EFFORT=max: $installed" >&2; exit 1; }
    [ -x "$installed" ] || { echo "installed elevation adapter lost its executable bit: $installed" >&2; exit 1; }
  done
done

# A second apply after a successful install makes no write.
inode_before=$(stat -c %i "$current/skills/ce-plan/scripts/elevation-dispatch.sh")
env HOME="$home" bash "$prov"
inode_after=$(stat -c %i "$current/skills/ce-plan/scripts/elevation-dispatch.sh")
[ "$inode_before" = "$inode_after" ] \
  || { echo "second apply rewrote an already-installed elevation adapter" >&2; exit 1; }

# Offline argv check: the installed adapter's own --emit-adapter test hook prints
# its argv without calling a real CLI.
mapfile -d '' installed_argv < <("$current/skills/ce-plan/scripts/elevation-dispatch.sh" --emit-adapter fable)
argv_carries_effort_max=0
for i in "${!installed_argv[@]}"; do
  if [ "${installed_argv[$i]}" = "--effort" ] && [ "${installed_argv[$((i + 1))]}" = "max" ]; then
    argv_carries_effort_max=1
    break
  fi
done
[ "$argv_carries_effort_max" = 1 ] \
  || { echo "installed elevation adapter argv does not carry --effort max" >&2; exit 1; }

# Fixture archive script has a different digest (neither upstream nor overlay):
# apply leaves it byte-identical and warns, without failing the run.
build_fake_ce
mkdir -p "$current/skills/ce-plan/scripts"
mismatched="$current/skills/ce-plan/scripts/elevation-dispatch.sh"
printf '#!/usr/bin/env bash\necho locally modified\n' > "$mismatched"
chmod 755 "$mismatched"
cp "$mismatched" "$scratch/expected-mismatched.sh"
if ! env HOME="$home" bash "$prov" 2>"$scratch/guarded.err"; then
  echo "provisioner exited nonzero on a mismatched elevation adapter" >&2; exit 1
fi
cmp -s "$scratch/expected-mismatched.sh" "$mismatched" \
  || { echo "mismatched elevation adapter was changed" >&2; exit 1; }
grep -qF "$mismatched" "$scratch/guarded.err" \
  || { echo "mismatched elevation adapter warning does not name the file" >&2; exit 1; }
grep -qF 'does not match the pinned upstream digest' "$scratch/guarded.err" \
  || { echo "mismatched elevation adapter warning text missing" >&2; exit 1; }

# --- CLI elevation adapter overlay: portable digest tool selection ---
# macOS ships no sha256sum, only `shasum -a 256`; a PATH built from symlinks to
# only the tools the provisioner needs, following resolve_in()'s style in
# .ci/test-bun-resolve.sh, proves the digest check does not depend on which one
# is present, and never aborts the apply when neither is.
bash_bin="$(command -v bash)"
real_sha256sum="$(command -v sha256sum)"
core_tools=(mkdir cp mv rm cmp dirname readlink cut)
symlink_core_tools() {   # <bin-dir> -> symlink each core tool into bin-dir
  local dir=$1 tool
  for tool in "${core_tools[@]}"; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
}

bin_no_sha256sum="$scratch/bin-shasum-only"
mkdir -p "$bin_no_sha256sum"
symlink_core_tools "$bin_no_sha256sum"
# Emulates macOS `shasum -a 256 -- <path>` by delegating to the real sha256sum,
# which does not understand the `-a 256` algorithm selector. An absolute-path
# shebang, not `#!/usr/bin/env bash`, because this PATH deliberately carries no
# `bash` or `env` entry for env to resolve against.
cat > "$bin_no_sha256sum/shasum" <<EOF
#!$bash_bin
shift 2
exec "$real_sha256sum" "\$@"
EOF
chmod 755 "$bin_no_sha256sum/shasum"

bin_no_digest_tool="$scratch/bin-no-digest-tool"
mkdir -p "$bin_no_digest_tool"
symlink_core_tools "$bin_no_digest_tool"

# Rung: sha256sum absent, shasum present -> the overlay still installs.
build_fake_ce
install_upstream_elevation_adapters
env HOME="$home" PATH="$bin_no_sha256sum" "$bash_bin" "$prov"
cmp -s "$ce_plan_overlay" "$current/skills/ce-plan/scripts/elevation-dispatch.sh" \
  || { echo "elevation adapter did not install with sha256sum absent and shasum present" >&2; exit 1; }

# Rung: neither tool on PATH -> warn, skip the guarded entries, still exit 0.
build_fake_ce
mkdir -p "$current/skills/ce-plan/scripts"
install -m 755 "$reconstructed_upstream" "$current/skills/ce-plan/scripts/elevation-dispatch.sh"
cp "$current/skills/ce-plan/scripts/elevation-dispatch.sh" "$scratch/expected-no-digest-tool.sh"
if ! env HOME="$home" PATH="$bin_no_digest_tool" "$bash_bin" "$prov" 2>"$scratch/no-digest-tool.err"; then
  echo "provisioner exited nonzero with no sha256 tool on PATH" >&2; exit 1
fi
cmp -s "$scratch/expected-no-digest-tool.sh" "$current/skills/ce-plan/scripts/elevation-dispatch.sh" \
  || { echo "elevation adapter changed with no sha256 tool on PATH" >&2; exit 1; }
grep -qF 'no sha256 tool' "$scratch/no-digest-tool.err" \
  || { echo "missing sha256-tool warning" >&2; exit 1; }
grep -qF "$current/skills/ce-plan/scripts/elevation-dispatch.sh" "$scratch/no-digest-tool.err" \
  || { echo "sha256-tool warning does not name the file" >&2; exit 1; }

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
printf '%s\n' "$ce_block" | grep -qxF 'exclude = ["*/skills/ce-sweep/references/interview.md"]' \
  || { echo "rendered CE external missing exclude for interview.md" >&2; exit 1; }
grep -q '^exact = true$' "$rendered_externals" \
  || { echo "agent-skills exact archives unexpectedly changed" >&2; exit 1; }

# --- agent skill external is exact: skills/i-have-adhd from ayghri/i-have-adhd ---
skill_block=$(awk '
  /^\["\.agents\/skills\/i-have-adhd"\]/ { in_skill=1; first=1 }
  in_skill && !first && /^\[/ { exit }
  in_skill { print; first=0 }
' "$rendered_externals")
printf '%s\n' "$skill_block" | grep -q '^type = "archive"$' \
  || { echo "rendered i-have-adhd skill external block missing" >&2; exit 1; }
printf '%s\n' "$skill_block" | grep -q '^exact = true$' \
  || { echo "rendered i-have-adhd skill external is not exact" >&2; exit 1; }
printf '%s\n' "$skill_block" | grep -q '^stripComponents = 3$' \
  || { echo "rendered i-have-adhd skill external lost stripComponents" >&2; exit 1; }
printf '%s\n' "$skill_block" | grep -qxF 'include = ["*/skills/i-have-adhd/**"]' \
  || { echo "rendered i-have-adhd skill external lost include" >&2; exit 1; }
skill_ref=$(jq -er '.releases.tools["i-have-adhd"].version' "$root/.chezmoidata/releases.json")
printf '%s\n' "$skill_block" |
  grep -Fx "url = 'https://github.com/ayghri/i-have-adhd/archive/$skill_ref.tar.gz'" >/dev/null ||
  { echo "rendered i-have-adhd skill external has wrong URL" >&2; exit 1; }

prune_home="$scratch/prune-home"
ce_current="$prune_home/.local/share/compound-engineering/$version"
mkdir -p "$ce_current" \
  "$prune_home/.local/share/compound-engineering/v-stale"
foreign="$scratch/prune-foreign"
mkdir -p "$foreign"
ln -s "$foreign" "$prune_home/.local/share/compound-engineering/foreign"
env HOME="$prune_home" bash "$prune"
[[ -d $ce_current ]]
[[ ! -e $prune_home/.local/share/compound-engineering/v-stale ]]
[[ -L $prune_home/.local/share/compound-engineering/foreign ]]

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

# --- interview content contract ---
interview_file="$root/dot_local/share/compound-engineering-overlays/skills/ce-sweep/references/interview.md"
[ -f "$interview_file" ] || { echo "interview overlay missing: $interview_file" >&2; exit 1; }
grep -qF -- 'gitlab-issues' "$interview_file" || { echo "interview missing gitlab-issues" >&2; exit 1; }
grep -qF -- 'group/project' "$interview_file" || { echo "interview missing group/project target" >&2; exit 1; }
grep -qF -- 'feedback:ack' "$interview_file" || { echo "interview missing feedback:ack label" >&2; exit 1; }
grep -qF -- 'feedback:resolved' "$interview_file" || { echo "interview missing feedback:resolved label" >&2; exit 1; }
echo "compound-engineering overlays: ok"
