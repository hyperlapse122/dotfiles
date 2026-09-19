#!/usr/bin/env bash
# Isolated, network-free verification of the compound-engineering overlay provisioner
# and of the static shape of the committed patch set.
#
# The provisioner is rendered from a fixture source root. Its overlay directory is a
# fixture patch set that the rebase driver generates from .ci/fixtures/ce-overlays and
# stamps with the real pin, so the rendered script embeds fixture digests. The upstream
# gate .ci/check-ce-overlay-patches.sh owns the persona, interview, and effort content
# contracts; this test owns the apply-time behavior:
#   - a fresh version directory receives all four post-images in both CE copies,
#     byte-identical to the fixture post-images, executable only for the adapters
#   - a converged tree changes no inode; a stale post-image, a foreign or same-content
#     symlink, and a directory at a target are replaced; a wrong mode is fixed in place
#   - a non-plain directory in the archive-owned chain fails the run with exit 1
#     before any file is installed, in either copy and on either install path
#   - a missing git, a base.json tag that differs from the directory, a pristine file
#     that differs from its pre-image, a pristine file at the absent path, a patch that
#     does not apply, and a post-image mismatch each degrade every path in every copy
#     together, and the run still exits 0; a destination at the absent path survives
#   - the install is a transaction: a cp or mv that fails part-way undoes every earlier
#     install, degrades every path, and leaves no temp file; when the degrade install
#     fails too, the whole tree is unchanged and the run still exits 0
#   - a symlinked version directory is skipped; a missing overlay or version directory
#     changes nothing; a shasum-only PATH installs; no sha256 tool changes nothing
#   - the scratch directory is gone after every run
#   - the real overlay directory holds only patches/** and base.json, and the committed
#     patch set, externals, pruner, and rendered provisioner agree
#
set -euo pipefail

root=${1:-$(pwd)}
# shellcheck source=.ci/lib/source-root.sh
source "$root/.ci/lib/source-root.sh"
source_root=$(resolve_source_root "$root")
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/ce-overlays.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() {
  printf 'test-compound-engineering-overlays: %s\n' "$*" >&2
  exit 1
}

# --- stub op + empty config so execute-template never hits live 1Password ---
bin="$scratch/bin"
mkdir -p "$bin"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$bin/op"
chmod 700 "$bin/op"

# render() owns the stub-`op` PATH, the empty config and the throwaway destination.
# Its scratch directory is separate from $home, which build_fake_ce recreates.
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$root/.ci/lib/render-gate-helpers.sh"
chezmoi_bin=$(command -v chezmoi)
render_scratch="$scratch/render"
mkdir -p "$render_scratch/bin" "$render_scratch/home" "$render_scratch/target"
cp "$bin/op" "$render_scratch/bin/op"
: > "$render_scratch/empty.toml"
render_source_template() { # <source-state path> <output> [override-data]
  render "$root" "$render_scratch" "$chezmoi_bin" linux "$source_root/$1" "$2" "${3:-}"
}

provisioner_template=.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.sh.tmpl
# The run_after_ name is load-bearing: the destination sits in a deliberately
# additive, third-party-writable tree, so the reference has to be re-asserted on
# every apply. A fingerprinted onchange run records a clean skip and would never
# repair live drift such as a foreign symlink at the reference path.
case "$source_root/$provisioner_template" in
  *"/run_onchange_"*) fail "overlay provisioner must retry on every apply" ;;
  *"/run_after_"*) ;;
  *) fail "overlay provisioner must use the run_after_ lifecycle" ;;
esac

# --- fixture patch set on a fixture source root ---
tag=$(jq -er '.releases.tools["compound-engineering"].version' "$source_root/.chezmoidata/releases.json")
k_int=skills/ce-sweep/references/interview.md
k_persona=skills/ce-sweep/references/sources/gitlab-issues.md
k_plan=skills/ce-plan/scripts/elevation-dispatch.sh
k_brain=skills/ce-brainstorm/scripts/elevation-dispatch.sh
keys=("$k_plan" "$k_brain" "$k_int" "$k_persona")

stage_fixture_tree() { # <fixture subdirectory> <dest>
  mkdir -p "$2"
  cp -Rp "$root/.ci/fixtures/ce-overlays/$1/." "$2/"
  chmod 0755 "$2/$k_plan" "$2/$k_brain"
}
fx_upstream="$scratch/fx-upstream"
fx_post="$scratch/fx-post"
stage_fixture_tree upstream-old "$fx_upstream"
stage_fixture_tree postimage "$fx_post"

[[ -f "$root/.chezmoiroot" ]] || fail "the fixture source root needs the repository .chezmoiroot"
fx_repo="$scratch/fx-repo"
mkdir -p "$fx_repo"
for entry in "$root"/* "$root"/.[!.]*; do
  [[ -e "$entry" ]] || continue
  ln -s -- "$entry" "$fx_repo/${entry##*/}"
done
fx_source=$(populate_fixture_source_root "$fx_repo" "$source_root")
rm -f -- "$fx_source/dot_local"
mkdir -p "$fx_source/dot_local/share"
for entry in "$source_root/dot_local/share"/* "$source_root/dot_local/share"/.[!.]*; do
  [[ -e "$entry" ]] || continue
  if [[ ${entry##*/} != compound-engineering-overlays ]]; then
    ln -s -- "$entry" "$fx_source/dot_local/share/${entry##*/}"
  fi
done
fx_overlays="$fx_source/dot_local/share/compound-engineering-overlays"
seed_posts=()
for key in "${keys[@]}"; do seed_posts+=(--post "$key=$fx_post/$key"); done
"$root/.ci/ce-overlay-rebase.sh" seed --overlay-dir "$fx_overlays" \
  --lock "$source_root/.chezmoidata/releases.json" --pristine-dir "$fx_upstream" \
  --target-tag "$tag" "${seed_posts[@]}" > "$scratch/seed.out" \
  || fail "the rebase driver could not seed the fixture patch set"
[[ $(jq -r '.version' "$fx_overlays/base.json") == "$tag" ]] || fail "the fixture patch set is not stamped with the pin $tag"

prov="$scratch/provisioner.sh"
render "$fx_repo" "$render_scratch" "$chezmoi_bin" linux "$fx_source/$provisioner_template" "$prov"
real_prov="$scratch/real-provisioner.sh"
render_source_template "$provisioner_template" "$real_prov"

# The rendered script resolves CURRENT="$BASE_DIR/v<semver>" with BASE_DIR under $HOME.
# Point HOME at a scratch tree and build the matching structure there.
home="$scratch/home"
version=$(grep -oE '"\$HOME/\.local/share/compound-engineering/v[0-9][0-9.]*"' "$prov" | sed -E 's|.*/(v[0-9][0-9.]+)"$|\1|' | head -1)
[ -n "$version" ] || fail "could not resolve CE version from rendered script"

ce_base="$home/.local/share/compound-engineering"
overlays="$home/.local/share/compound-engineering-overlays"
pristine="$home/.local/share/compound-engineering-pristine/$version"
current="$ce_base/$version"
# omp's own copy of the same archive. It carries no root plugin.json, because
# that file makes omp misclassify the tree and drop 30 of 33 skills (cb30ed4),
# while agy needs it present in the copy above. The provisioner must overlay
# both copies, or omp gets a ce-sweep whose references are missing.
omp_current="$home/.local/share/compound-engineering-omp/$version"
copies=("$current" "$omp_current")

build_fake_ce() {
  local dir source_name
  rm -rf "$home"
  for dir in "${copies[@]}"; do
    mkdir -p "$dir/skills/ce-sweep/references/sources"
    cp "$root/.ci/fixtures/ce-sweep/SKILL.md" "$dir/skills/ce-sweep/SKILL.md"
    for source_name in email github-issues slack; do
      printf 'upstream %s\n' "$source_name" > "$dir/skills/ce-sweep/references/sources/$source_name.md"
    done
  done
  printf '{"name":"compound-engineering"}\n' > "$current/plugin.json"
  mkdir -p "$pristine" "$overlays"
  cp -Rp "$fx_upstream/." "$pristine/"
  cp -Rp "$fx_overlays/." "$overlays/"
}

want_mode() { # <key> -> the recorded permission bits
  case $1 in
    */elevation-dispatch.sh) printf 755 ;;
    *) printf 644 ;;
  esac
}

bash_bin=$(command -v bash)
prov_tmp="$scratch/prov-tmp"
prov_status=0
run_prov() { # <script> <stderr file> [PATH directory] -> sets prov_status; fails when the scratch directory survives
  local script=$1 err=$2 path_dir=${3:-}
  rm -rf "$prov_tmp"
  mkdir -p "$prov_tmp"
  prov_status=0
  if [ -n "$path_dir" ]; then
    env HOME="$home" PATH="$path_dir" TMPDIR="$prov_tmp" "$bash_bin" "$script" 2> "$err" || prov_status=$?
  else
    env HOME="$home" TMPDIR="$prov_tmp" "$bash_bin" "$script" 2> "$err" || prov_status=$?
  fi
  [ -z "$(ls -A "$prov_tmp")" ] || fail "the provisioner left its scratch directory behind: $(ls -A "$prov_tmp")"
}
run_ok() { # <label> <script> <stderr file> [PATH directory]
  local label=$1
  shift
  run_prov "$@"
  [ "$prov_status" = 0 ] || fail "$label: the provisioner exited $prov_status: $(cat "$2")"
}

assert_same() { # <label> <expected file> <actual file>
  cmp -s "$2" "$3" || fail "$1: $3 differs from $2"
}

assert_post_images() { # <label>
  local dir key
  for dir in "${copies[@]}"; do
    for key in "${keys[@]}"; do
      if ! { [ -f "$dir/$key" ] && [ ! -L "$dir/$key" ]; }; then fail "$1: $dir/$key is not a regular file"; fi
      assert_same "$1" "$fx_post/$key" "$dir/$key"
      [ "$(stat -c '%a' "$dir/$key")" = "$(want_mode "$key")" ] || fail "$1: $dir/$key has mode $(stat -c '%a' "$dir/$key"), want $(want_mode "$key")"
    done
  done
}

assert_archive_owned_untouched() { # <label>
  local dir source_name
  for dir in "${copies[@]}"; do
    assert_same "$1" "$root/.ci/fixtures/ce-sweep/SKILL.md" "$dir/skills/ce-sweep/SKILL.md"
    for source_name in email github-issues slack; do
      [ "$(cat "$dir/skills/ce-sweep/references/sources/$source_name.md")" = "upstream $source_name" ] \
        || fail "$1: upstream $source_name.md changed in $dir"
    done
  done
  [ -e "$current/plugin.json" ] || fail "$1: root plugin.json missing"
  [ ! -e "$omp_current/plugin.json" ] || fail "$1: the omp copy gained a root plugin.json"
}

assert_pristine() { # <label> <destination> <key>: the unmodified upstream file, with its recorded mode
  assert_same "$1" "$pristine/$3" "$2"
  [ "$(stat -c '%a' "$2")" = "$(want_mode "$3")" ] || fail "$1: $2 has mode $(stat -c '%a' "$2"), want $(want_mode "$3")"
}

assert_warns_each_path() { # <label> <stderr file>
  local dir key
  for dir in "${copies[@]}"; do
    for key in "${keys[@]}"; do
      grep -qF "$dir/$key" "$2" || fail "$1: no warning names $dir/$key"
    done
  done
}

assert_no_post_image() { # <label> <destination> <key>
  if [ -f "$2" ] && cmp -s "$fx_post/$3" "$2"; then
    fail "$1: the patched result was installed at $2"
  fi
}

snapshot() { # <dir>
  find "$1" -exec stat -c '%n %F %i %a %s %Y' {} + | LC_ALL=C sort
}

tree_state() { # <dir> -> every entry with its type, permission bits and link target, plus file digests; no inode or directory time
  find "$1" -exec stat -c '%N %F %a' {} + | LC_ALL=C sort
  find "$1" -type f -exec sha256sum -- {} + | LC_ALL=C sort
}

assert_no_transaction_debris() { # <label>
  local debris
  debris=$(find "$home" -name '*.chezmoi-*' -print)
  [ -z "$debris" ] || fail "$1: temp or backup files remain: $debris"
}

inodes() {
  local dir key
  for dir in "${copies[@]}"; do
    for key in "${keys[@]}"; do
      stat -c '%i' "$dir/$key"
    done
  done
}

# --- fresh version directory: all four post-images in both copies ---
build_fake_ce
run_ok "fresh install" "$prov" "$scratch/fresh.err"
[ ! -s "$scratch/fresh.err" ] || fail "a fresh install warned: $(cat "$scratch/fresh.err")"
assert_post_images "fresh install"
assert_archive_owned_untouched "fresh install"

# --- a converged tree: a second run changes no inode and stays silent ---
inodes_before=$(inodes)
run_ok "second run" "$prov" "$scratch/second.err"
[ "$(inodes)" = "$inodes_before" ] || fail "a second run rewrote an already-installed file"
[ ! -s "$scratch/second.err" ] || fail "a converged run warned: $(cat "$scratch/second.err")"
# A later archive reconciliation restores archive-owned files. The provisioner
# must leave every archive-owned file unchanged.
assert_archive_owned_untouched "second run"

# --- a stale post-image is replaced (the stale-effort case) ---
for dir in "${copies[@]}"; do
  for key in "${keys[@]}"; do
    printf 'older post-image\n' > "$dir/$key"
  done
done
run_ok "stale post-image" "$prov" "$scratch/stale.err"
assert_post_images "stale post-image"

# --- the recorded bytes with the wrong mode: the mode is fixed in place ---
chmod 0644 "$current/$k_plan" "$omp_current/$k_brain"
chmod 0755 "$current/$k_int" "$omp_current/$k_persona"
inodes_before=$(inodes)
run_ok "wrong mode" "$prov" "$scratch/mode.err"
[ "$(inodes)" = "$inodes_before" ] || fail "fixing a mode rewrote the file"
assert_post_images "wrong mode"

# --- foreign symlink at a target: reclaim it, never write through it ---
# Agents wire a project-local ce-sweep source into this shared tree. Copying
# through the link would overwrite a tracked file in that checkout, and the
# escaping links must also fail any later source-tree validation.
build_fake_ce
foreign="$scratch/foreign-checkout/.compound-engineering/ce-sweep/sources"
mkdir -p "$foreign"
printf 'project-local persona\n' > "$foreign/gitlab-issues.md"
cp "$foreign/gitlab-issues.md" "$scratch/expected-foreign.md"
mkdir -p "$current/skills/ce-sweep/references/sources"
ln -sfn "$foreign/gitlab-issues.md" "$current/$k_persona"
# A symlink to the correct content is reclaimed too, not trusted on a digest match.
mkdir -p "$current/skills/ce-plan/scripts"
ln -sfn "$fx_post/$k_plan" "$current/$k_plan"
run_ok "symlink reclaim" "$prov" "$scratch/symlink.err"
[ ! -L "$current/$k_persona" ] || fail "foreign symlink survived the provisioner"
[ ! -L "$current/$k_plan" ] || fail "a same-content symlink survived the provisioner"
assert_post_images "symlink reclaim"
assert_same "symlink reclaim" "$scratch/expected-foreign.md" "$foreign/gitlab-issues.md"
grep -qF 'replaced foreign symlink' "$scratch/symlink.err" || fail "symlink reclaim did not warn"

# --- a directory at the added path is reclaimed and replaced ---
build_fake_ce
mkdir -p "$current/$k_persona"
printf 'not a file\n' > "$current/$k_persona/inside.md"
run_ok "directory reclaim" "$prov" "$scratch/dir.err"
assert_post_images "directory reclaim"

# --- foreign symlink in the archive-owned directory chain: refuse, do not delete ---
build_fake_ce
foreign_dir="$scratch/foreign-sources"
mkdir -p "$foreign_dir"
printf 'outside\n' > "$foreign_dir/keep.md"
rm -rf "$current/skills/ce-sweep/references/sources"
ln -sfn "$foreign_dir" "$current/skills/ce-sweep/references/sources"
state_before=$(snapshot "$home")
run_prov "$prov" "$scratch/chain.err"
[ "$prov_status" = 1 ] || fail "provisioner did not exit 1 for a symlinked directory component (exit $prov_status)"
grep -q 'is not a plain directory' "$scratch/chain.err" || fail "directory-chain conflict not reported"
[ "$(snapshot "$home")" = "$state_before" ] || fail "the refused run changed the tree"
[ -L "$current/skills/ce-sweep/references/sources" ] || fail "provisioner deleted an archive-owned directory component"
[ ! -e "$foreign_dir/gitlab-issues.md" ] || fail "provisioner wrote through the symlinked directory"
[ "$(cat "$foreign_dir/keep.md")" = outside ] || fail "provisioner disturbed the symlinked directory contents"

# --- restricted PATH directories: only the tools the provisioner needs ---
# The digest and git tools vary per rung, which shows the install does not depend
# on which digest tool is present and never aborts the apply when none is.
core_tools=(mkdir rmdir cp mv rm cmp dirname readlink cut chmod mktemp stat env)
make_bin_dir() { # <name> <extra tool>... -> prints the PATH directory
  local dir="$scratch/bin-$1" tool
  shift
  mkdir -p "$dir"
  for tool in "${core_tools[@]}" "$@"; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s' "$dir"
}
bin_no_git=$(make_bin_dir no-git sha256sum)
bin_no_digest=$(make_bin_dir no-digest git)
bin_shasum=$(make_bin_dir shasum git)
# Emulates macOS `shasum -a 256 -- <path>` by delegating to the real sha256sum,
# which does not understand the `-a 256` algorithm selector. An absolute-path
# shebang, not `#!/usr/bin/env bash`, because this PATH deliberately carries no
# `bash` entry for env to resolve against.
cat > "$bin_shasum/shasum" <<EOF
#!$bash_bin
shift 2
exec "$(command -v sha256sum)" "\$@"
EOF
chmod 755 "$bin_shasum/shasum"
# A PATH directory whose <tool> fails when "<previous argument>@<last argument>"
# matches <pattern>, and otherwise runs the real tool. It injects one failing cp
# or mv into an otherwise working provisioner.
make_failing_dir() { # <name> <tool> <pattern> -> prints the PATH directory
  local dir="$scratch/bin-$1" tool
  mkdir -p "$dir"
  for tool in "${core_tools[@]}" git sha256sum; do
    [ "$tool" = "$2" ] || ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  cat > "$dir/$2" <<EOF
#!$bash_bin
prev=''
last=''
for arg in "\$@"; do
  prev=\$last
  last=\$arg
done
case "\$prev@\$last" in
  $3)
    echo "$2: injected failure" >&2
    exit 1
    ;;
esac
exec "$(command -v "$2")" "\$@"
EOF
  chmod 755 "$dir/$2"
  printf '%s' "$dir"
}

# --- AE5: no git degrades every path together, then the next apply patches ---
build_fake_ce
run_ok "no git" "$prov" "$scratch/no-git.err" "$bin_no_git"
for dir in "${copies[@]}"; do
  for key in "$k_plan" "$k_brain" "$k_int"; do
    assert_pristine "no git" "$dir/$key" "$key"
  done
  [ ! -e "$dir/$k_persona" ] || fail "no git: the added path received a file in $dir"
done
assert_warns_each_path "no git" "$scratch/no-git.err"
grep -qF 'git' "$scratch/no-git.err" || fail "no git: the warning does not name git"
assert_archive_owned_untouched "no git"
run_ok "git returns" "$prov" "$scratch/git-returns.err"
assert_post_images "git returns"
# A converged tree needs no git and is left unchanged.
state_before=$(snapshot "$home")
run_ok "converged, no git" "$prov" "$scratch/converged-no-git.err" "$bin_no_git"
[ "$(snapshot "$home")" = "$state_before" ] || fail "a converged tree changed without git"
[ ! -s "$scratch/converged-no-git.err" ] || fail "a converged tree warned without git: $(cat "$scratch/converged-no-git.err")"

# --- a foreign directory component in the second copy is refused before the first copy is touched ---
# The refusal has to precede every install, or the first copy would be patched while
# the second keeps a customized interview without its added source.
for chain_label in patched degraded; do
  if [ "$chain_label" = degraded ]; then
    chain_path=$bin_no_git
    chain_component=skills/ce-plan/scripts
  else
    chain_path=''
    chain_component=skills/ce-sweep/references/sources
  fi
  build_fake_ce
  rm -rf "${omp_current:?}/$chain_component"
  mkdir -p "$(dirname "$omp_current/$chain_component")"
  ln -sfn "$foreign_dir" "$omp_current/$chain_component"
  state_before=$(snapshot "$home")
  run_prov "$prov" "$scratch/chain-omp.err" "$chain_path"
  [ "$prov_status" = 1 ] || fail "$chain_label chain refusal in the second copy exited $prov_status, want 1"
  grep -q 'is not a plain directory' "$scratch/chain-omp.err" || fail "$chain_label chain refusal in the second copy was not reported"
  [ "$(snapshot "$home")" = "$state_before" ] || fail "$chain_label chain refusal in the second copy changed the tree"
done

# --- a failing mv on the last install undoes every earlier install, then degrades every path ---
# Seven of eight paths are installed when the last mv fails. The two foreign
# entries at the added path have to come back exactly as they were.
build_fake_ce
foreign_file="$scratch/foreign-persona.md"
printf 'foreign persona\n' > "$foreign_file"
ln -s "$foreign_file" "$current/$k_persona"
mkdir -p "$omp_current/$k_persona"
printf 'inside\n' > "$omp_current/$k_persona/inside.md"
bin_fail_last=$(make_failing_dir fail-last mv "*.chezmoi-*.tmp@$omp_current/$k_persona")
run_ok "failing last install" "$prov" "$scratch/fail-last.err" "$bin_fail_last"
grep -qF 'injected failure' "$scratch/fail-last.err" || fail "failing last install: the injected failure did not run"
for dir in "${copies[@]}"; do
  for key in "$k_plan" "$k_brain" "$k_int"; do
    assert_pristine "failing last install" "$dir/$key" "$key"
  done
done
if ! { [ -L "$current/$k_persona" ] && [ "$(readlink "$current/$k_persona")" = "$foreign_file" ]; }; then fail "failing last install: the foreign symlink was not restored"; fi
[ "$(cat "$foreign_file")" = 'foreign persona' ] || fail "failing last install: the foreign file changed"
[ "$(cat "$omp_current/$k_persona/inside.md")" = inside ] || fail "failing last install: the directory at the added path was not restored"
assert_warns_each_path "failing last install" "$scratch/fail-last.err"
assert_no_transaction_debris "failing last install"
assert_archive_owned_untouched "failing last install"

# --- when the degrade install fails as well, the whole tree is unchanged ---
build_fake_ce
for dir in "${copies[@]}"; do
  mkdir -p "$dir/skills/ce-plan/scripts" "$dir/skills/ce-brainstorm/scripts"
  for key in "$k_plan" "$k_brain" "$k_int"; do
    printf 'customized %s\n' "$key" > "$dir/$key"
  done
done
chmod 0600 "$omp_current/$k_int"
ln -s "$foreign_file" "$current/$k_persona"
state_before=$(tree_state "$home")
bin_fail_int=$(make_failing_dir fail-int mv "*.chezmoi-*.tmp@$omp_current/$k_int")
run_ok "failing degrade install" "$prov" "$scratch/fail-degrade.err" "$bin_fail_int"
[ "$(tree_state "$home")" = "$state_before" ] || fail "failing degrade install: the tree changed"
assert_warns_each_path "failing degrade install" "$scratch/fail-degrade.err"
assert_no_transaction_debris "failing degrade install"

# --- a failing cp while staging leaves no temp file and no new directory ---
build_fake_ce
state_before=$(tree_state "$home")
bin_fail_stage=$(make_failing_dir fail-stage cp "*@$omp_current/$k_plan.chezmoi-*.tmp")
run_ok "failing staging" "$prov" "$scratch/fail-stage.err" "$bin_fail_stage"
grep -qF 'injected failure' "$scratch/fail-stage.err" || fail "failing staging: the injected failure did not run"
[ "$(tree_state "$home")" = "$state_before" ] || fail "failing staging: the tree changed"
assert_warns_each_path "failing staging" "$scratch/fail-stage.err"
assert_no_transaction_debris "failing staging"

# --- portable digest tool selection ---
build_fake_ce
run_ok "shasum only" "$prov" "$scratch/shasum.err" "$bin_shasum"
assert_post_images "shasum only"
build_fake_ce
state_before=$(snapshot "$home")
run_ok "no digest tool" "$prov" "$scratch/no-digest.err" "$bin_no_digest"
[ "$(snapshot "$home")" = "$state_before" ] || fail "the tree changed with no sha256 tool on PATH"
[ "$(grep -c 'no sha256 tool' "$scratch/no-digest.err")" = 1 ] || fail "expected exactly one sha256-tool warning: $(cat "$scratch/no-digest.err")"

# --- a base.json tag that differs from the directory degrades every path ---
mismatched_prov="$scratch/provisioner-mismatched-tag.sh"
sed 's/^BASE_TAG=.*/BASE_TAG="compound-engineering-v0.0.0"/' "$prov" > "$mismatched_prov"
grep -qx 'BASE_TAG="compound-engineering-v0.0.0"' "$mismatched_prov" || fail "could not patch BASE_TAG for the tag-mismatch fixture"
build_fake_ce
run_ok "tag mismatch" "$mismatched_prov" "$scratch/tag.err"
for dir in "${copies[@]}"; do
  for key in "$k_plan" "$k_brain" "$k_int"; do
    assert_pristine "tag mismatch" "$dir/$key" "$key"
  done
  [ ! -e "$dir/$k_persona" ] || fail "tag mismatch: the added path received a file in $dir"
done
assert_warns_each_path "tag mismatch" "$scratch/tag.err"

# --- one pristine file whose sha256 differs degrades both copies ---
build_fake_ce
printf 'moved upstream\n' >> "$pristine/$k_int"
for dir in "${copies[@]}"; do
  printf 'current interview\n' > "$dir/$k_int"
done
run_ok "pristine sha256 mismatch" "$prov" "$scratch/sha.err"
for dir in "${copies[@]}"; do
  [ "$(cat "$dir/$k_int")" = 'current interview' ] || fail "the mismatched path changed in $dir"
  for key in "$k_plan" "$k_brain"; do
    assert_pristine "pristine sha256 mismatch" "$dir/$key" "$key"
  done
  [ ! -e "$dir/$k_persona" ] || fail "pristine sha256 mismatch: the added path received a file in $dir"
done
assert_warns_each_path "pristine sha256 mismatch" "$scratch/sha.err"

# --- a pristine file with the wrong mode degrades the same way ---
build_fake_ce
chmod 0644 "$pristine/$k_plan"
for dir in "${copies[@]}"; do
  mkdir -p "$dir/skills/ce-plan/scripts"
  printf 'current adapter\n' > "$dir/$k_plan"
done
run_ok "pristine mode mismatch" "$prov" "$scratch/pre-mode.err"
for dir in "${copies[@]}"; do
  [ "$(cat "$dir/$k_plan")" = 'current adapter' ] || fail "the mode-mismatched path changed in $dir"
  assert_pristine "pristine mode mismatch" "$dir/$k_brain" "$k_brain"
  assert_pristine "pristine mode mismatch" "$dir/$k_int" "$k_int"
done
assert_warns_each_path "pristine mode mismatch" "$scratch/pre-mode.err"

# --- a pristine file at the added path: no verified pre-image, so the target stays as it is ---
build_fake_ce
mkdir -p "$pristine/skills/ce-sweep/references/sources"
printf 'upstream persona\n' > "$pristine/$k_persona"
printf 'customized persona\n' > "$current/$k_persona"
chmod 0600 "$current/$k_persona"
state_before=$(tree_state "$current/skills/ce-sweep/references/sources")
run_ok "collision" "$prov" "$scratch/collision.err"
for dir in "${copies[@]}"; do
  for key in "$k_plan" "$k_brain" "$k_int"; do
    assert_pristine "collision" "$dir/$key" "$key"
  done
done
[ "$(tree_state "$current/skills/ce-sweep/references/sources")" = "$state_before" ] || fail "collision: the existing target at the added path changed"
[ "$(cat "$current/$k_persona")" = 'customized persona' ] || fail "collision: the existing target lost its content"
[ "$(stat -c '%a' "$current/$k_persona")" = 600 ] || fail "collision: the existing target lost its mode"
[ ! -e "$omp_current/$k_persona" ] || fail "collision: a file appeared at the absent path in $omp_current"
assert_warns_each_path "collision" "$scratch/collision.err"
assert_no_transaction_debris "collision"

# --- a patch that does not apply degrades every path ---
build_fake_ce
sed 's/^-EFFORT=.*/-EFFORT="not the upstream line"/' "$fx_overlays/patches/$k_plan.patch" > "$overlays/patches/$k_plan.patch"
grep -qF 'not the upstream line' "$overlays/patches/$k_plan.patch" || fail "could not break the patch for the conflict fixture"
run_ok "patch conflict" "$prov" "$scratch/conflict.err"
for dir in "${copies[@]}"; do
  for key in "$k_plan" "$k_brain" "$k_int"; do
    assert_pristine "patch conflict" "$dir/$key" "$key"
  done
  [ ! -e "$dir/$k_persona" ] || fail "patch conflict: the added path received a file in $dir"
done
assert_warns_each_path "patch conflict" "$scratch/conflict.err"

# --- a patch whose result differs from the recorded post-image degrades every path ---
build_fake_ce
sed 's/^+EFFORT=.*/+EFFORT="another effort"/' "$fx_overlays/patches/$k_plan.patch" > "$overlays/patches/$k_plan.patch"
grep -qF 'another effort' "$overlays/patches/$k_plan.patch" || fail "could not alter the patch for the post-image fixture"
run_ok "post-image mismatch" "$prov" "$scratch/post.err"
for dir in "${copies[@]}"; do
  for key in "${keys[@]}"; do
    assert_no_post_image "post-image mismatch" "$dir/$key" "$key"
  done
  for key in "$k_plan" "$k_brain" "$k_int"; do
    assert_pristine "post-image mismatch" "$dir/$key" "$key"
  done
done
assert_warns_each_path "post-image mismatch" "$scratch/post.err"

# --- a version directory that is a symlink is skipped with a warning ---
build_fake_ce
elsewhere="$scratch/elsewhere"
mv "$current" "$elsewhere"
ln -s "$elsewhere" "$current"
run_ok "symlinked version directory" "$prov" "$scratch/link-dir.err"
grep -qF "$current" "$scratch/link-dir.err" || fail "the skipped symlinked directory is not named in a warning"
for key in "${keys[@]}"; do
  [ ! -e "$elsewhere/$key" ] || fail "the provisioner wrote through the symlinked version directory: $key"
  assert_same "symlinked version directory" "$fx_post/$key" "$omp_current/$key"
done

# --- a missing overlay directory or a missing version directory changes nothing ---
build_fake_ce
rm -rf "$overlays"
state_before=$(snapshot "$home")
run_ok "missing overlay directory" "$prov" "$scratch/no-overlay.err"
[ "$(snapshot "$home")" = "$state_before" ] || fail "the tree changed when the overlay directory was absent"
build_fake_ce
rm -rf "$current" "$omp_current"
run_ok "missing version directories" "$prov" "$scratch/no-version.err"
if ! { [ ! -e "$current" ] && [ ! -e "$omp_current" ]; }; then fail "a CE version directory was recreated when absent"; fi

# --- the provisioner keeps no guard table and no associative array ---
if grep -q 'GUARDED_' "$real_prov" "$prov"; then
  fail "the rendered provisioner still carries a GUARDED_ identifier"
fi
if grep -qE 'declare -A|local -A|typeset -A|mapfile|readarray' "$real_prov"; then
  fail "the rendered provisioner uses a bash 4 feature"
fi

# --- CE external is additive: inspect its rendered table, not template source ---
rendered_externals="$scratch/ai-agents.toml"
prune="$scratch/prune.sh"
render_source_template .chezmoiexternals/ai-agents.toml "$rendered_externals"
render_source_template .chezmoiscripts/70-agents/run_onchange_after_zz-prune-agent-marketplace-archives.sh.tmpl "$prune"
ce_block=$(awk '
  /^\["\.local\/share\/compound-engineering\/v/ { in_ce=1; first=1 }
  in_ce && !first && /^\[/ { exit }
  in_ce { print; first=0 }
' "$rendered_externals")
printf '%s\n' "$ce_block" | grep -q '^type = "archive"$' \
  || fail "rendered CE external block missing"
if printf '%s\n' "$ce_block" | grep -q '^exact = true$'; then
  fail "rendered CE external is not additive"
fi
printf '%s\n' "$ce_block" | grep -qxF 'exclude = ["*/skills/ce-sweep/references/interview.md","*/skills/ce-plan/scripts/elevation-dispatch.sh","*/skills/ce-brainstorm/scripts/elevation-dispatch.sh","*/skills/ce-sweep/references/sources/gitlab-issues.md"]' \
  || fail "rendered CE external missing exclude for interview.md, gitlab-issues.md, and the elevation-dispatch adapters"
grep -q '^exact = true$' "$rendered_externals" \
  || fail "agent-skills exact archives unexpectedly changed"

# omp's own copy of the same archive carries the same excludes, plus its own
# root plugin.json exclude.
omp_ce_block=$(awk '
  /^\["\.local\/share\/compound-engineering-omp\/v/ { in_ce=1; first=1 }
  in_ce && !first && /^\[/ { exit }
  in_ce { print; first=0 }
' "$rendered_externals")
printf '%s\n' "$omp_ce_block" | grep -q '^type = "archive"$' \
  || fail "rendered CE-omp external block missing"
printf '%s\n' "$omp_ce_block" | grep -qxF 'exclude = ["*/skills/ce-sweep/references/interview.md","*/plugin.json","*/skills/ce-plan/scripts/elevation-dispatch.sh","*/skills/ce-brainstorm/scripts/elevation-dispatch.sh","*/skills/ce-sweep/references/sources/gitlab-issues.md"]' \
  || fail "rendered CE-omp external missing exclude for interview.md, gitlab-issues.md, plugin.json, and the elevation-dispatch adapters"

# --- agent skill external is exact: skills/i-have-adhd from ayghri/i-have-adhd ---
skill_block=$(awk '
  /^\["\.agents\/skills\/i-have-adhd"\]/ { in_skill=1; first=1 }
  in_skill && !first && /^\[/ { exit }
  in_skill { print; first=0 }
' "$rendered_externals")
printf '%s\n' "$skill_block" | grep -q '^type = "archive"$' \
  || fail "rendered i-have-adhd skill external block missing"
printf '%s\n' "$skill_block" | grep -q '^exact = true$' \
  || fail "rendered i-have-adhd skill external is not exact"
printf '%s\n' "$skill_block" | grep -q '^stripComponents = 3$' \
  || fail "rendered i-have-adhd skill external lost stripComponents"
printf '%s\n' "$skill_block" | grep -qxF 'include = ["*/skills/i-have-adhd/**"]' \
  || fail "rendered i-have-adhd skill external lost include"
skill_ref=$(jq -er '.releases.tools["i-have-adhd"].version' "$source_root/.chezmoidata/releases.json")
printf '%s\n' "$skill_block" |
  grep -Fx "url = 'https://github.com/ayghri/i-have-adhd/archive/$skill_ref.tar.gz'" >/dev/null ||
  fail "rendered i-have-adhd skill external has wrong URL"

prune_home="$scratch/prune-home"
ce_current="$prune_home/.local/share/compound-engineering/$version"
mkdir -p "$ce_current" \
  "$prune_home/.local/share/compound-engineering/v-stale"
prune_foreign="$scratch/prune-foreign"
mkdir -p "$prune_foreign"
ln -s "$prune_foreign" "$prune_home/.local/share/compound-engineering/foreign"
pristine_current="$prune_home/.local/share/compound-engineering-pristine/$version"
mkdir -p "$pristine_current" \
  "$prune_home/.local/share/compound-engineering-pristine/v-stale"
ln -s "$prune_foreign" "$prune_home/.local/share/compound-engineering-pristine/foreign"
env HOME="$prune_home" bash "$prune"
[[ -d $ce_current ]]
[[ ! -e $prune_home/.local/share/compound-engineering/v-stale ]]
[[ -L $prune_home/.local/share/compound-engineering/foreign ]]
[[ -d $pristine_current ]] \
  || fail "pruner removed the current pristine version directory"
[[ ! -e $prune_home/.local/share/compound-engineering-pristine/v-stale ]] \
  || fail "pruner left a stale pristine version directory"
[[ -L $prune_home/.local/share/compound-engineering-pristine/foreign ]] \
  || fail "pruner removed a symlink under the pristine path"

# --- patch set: schema, coverage, set equalities and the pristine external ---
overlay_src="$source_root/dot_local/share/compound-engineering-overlays"
base_json="$overlay_src/base.json"
[ -f "$base_json" ] || fail "base.json missing: $base_json"

# The overlay directory holds the patches and base.json, and nothing else.
stray_files=$(cd "$overlay_src" && find . -mindepth 1 ! -type d ! -path './patches/*' ! -path ./base.json)
[ -z "$stray_files" ] || fail "the overlay directory holds files other than patches/** and base.json: $stray_files"
if ! { [ -f "$base_json" ] && [ ! -L "$base_json" ]; }; then fail "base.json is not a regular file"; fi

jq -e '
  def sha: type == "string" and test("^[0-9a-f]{64}$");
  def mode: . == "0644" or . == "0755";
  (keys == ["paths", "version"])
  and (.version | test("^compound-engineering-v[0-9]+\\.[0-9]+\\.[0-9]+$"))
  and ((.paths | keys_unsorted) == (.paths | keys))
  and (.paths | to_entries | all(
    (.key | test("^[A-Za-z0-9_./-]+$") and (startswith("/") | not) and (test("(^|/)\\.\\.(/|$)") | not))
    and (.value | keys == ["mode", "postimage", "preimage"])
    and (.value.mode | mode)
    and (.value.postimage | keys == ["sha256"] and (.sha256 | sha))
    and (.value.preimage | . == "absent" or (keys == ["mode", "sha256"] and (.sha256 | sha) and (.mode | mode)))
  ))' "$base_json" >/dev/null \
  || fail "base.json does not match the schema"

base_tag=$(jq -er '.version' "$base_json")
pin_tag=$(jq -er '.releases.tools["compound-engineering"].version' "$source_root/.chezmoidata/releases.json")
[ "$base_tag" = "$pin_tag" ] \
  || fail "base.json records $base_tag but the lock pins $pin_tag; stamp base.json"
[ "v${base_tag#compound-engineering-v}" = "$version" ] \
  || fail "base.json tag $base_tag does not yield the resolved version segment $version"

base_keys=$(jq -r '.paths | keys[]' "$base_json" | LC_ALL=C sort)
expected_keys=$(LC_ALL=C sort <<'EOF'
skills/ce-brainstorm/scripts/elevation-dispatch.sh
skills/ce-plan/scripts/elevation-dispatch.sh
skills/ce-sweep/references/interview.md
skills/ce-sweep/references/sources/gitlab-issues.md
EOF
)
[ "$base_keys" = "$expected_keys" ] \
  || fail "base.json paths differ from the four declared patched paths"

patch_files=$(cd "$overlay_src/patches" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
expected_patch_files=$(while IFS= read -r key; do printf '%s.patch\n' "$key"; done <<<"$base_keys" | LC_ALL=C sort)
[ "$patch_files" = "$expected_patch_files" ] \
  || fail "patches/ does not hold exactly one patch per base.json path"
[ -z "$(find "$overlay_src/patches" ! -type f ! -type d)" ] \
  || fail "patches/ holds a link or special file"

while IFS= read -r key; do
  patch="$overlay_src/patches/$key.patch"
  header=$(sed '/^@@/q' "$patch")
  [ "$(grep -c '^diff --git ' "$patch")" = 1 ] \
    || fail "patch for $key holds more than one file diff"
  grep -qxF "diff --git a/$key b/$key" <<<"$header" \
    || fail "patch for $key does not name its own path in the diff header"
  grep -qxF "+++ b/$key" <<<"$header" \
    || fail "patch for $key does not write its own path"
  if [ "$(jq -r --arg key "$key" '.paths[$key].preimage' "$base_json")" = absent ]; then
    grep -qxF -- '--- /dev/null' <<<"$header" \
      || fail "patch for absent path $key does not create it"
  else
    grep -qxF -- "--- a/$key" <<<"$header" \
      || fail "patch for $key does not modify its own path"
  fi
  if grep -qE '^(rename |copy |similarity |dissimilarity |deleted file mode |old mode |new mode |Binary files |GIT binary patch)' <<<"$header"; then
    fail "patch for $key carries a rename, copy, delete, mode change, or binary record"
  fi
done <<<"$base_keys"

# The overlay's EFFORT must track the roster's claude authoring entry, not a
# literal, so a roster edit alone can flip this check (KTD2 parity with the
# claude-fable-5-1 settings leaf, which .ci/test-claude-settings-reconcile.sh
# holds to the same roster entry).
authoring_effort_tmpl="$scratch/authoring-effort.tmpl"
printf '%s' '{{ (includeTemplate "agent-roster-lookup.tmpl" (dict "roster" .agents.roster "agent" "claude" "shape" "authoring" "rung" "" "name" "a claude authoring entry") | fromJson).effort }}' \
  > "$authoring_effort_tmpl"
render "$root" "$render_scratch" "$chezmoi_bin" linux "$authoring_effort_tmpl" "$scratch/authoring-effort.out"
authoring_effort=$(<"$scratch/authoring-effort.out")
[ -n "$authoring_effort" ] || fail "could not resolve the roster claude authoring effort"

# An adapter patch changes the effort line and nothing else.
for adapter_key in "$k_plan" "$k_brain"; do
  adapter_patch="$overlay_src/patches/$adapter_key.patch"
  adapter_body=$(sed '1,/^@@/d' "$adapter_patch")
  if ! { [ "$(grep -c '^@@' "$adapter_patch")" = 1 ] \
    && [ "$(grep -c '^-' <<<"$adapter_body")" = 1 ] \
    && [ "$(grep -c '^+' <<<"$adapter_body")" = 1 ]; }; then fail "adapter patch for $adapter_key changes more than one line"; fi
  grep -q '^-EFFORT="' <<<"$adapter_body" \
    || fail "adapter patch for $adapter_key does not remove the upstream effort line"
  grep -qE "^\+EFFORT=\"$authoring_effort\"([[:space:]]|\$)" <<<"$adapter_body" \
    || fail "adapter patch for $adapter_key does not assign the roster authoring effort $authoring_effort"
done

# The pristine external: same archive, include-only, and a directory nothing else writes.
pristine_block=$(awk -v header="[\".local/share/compound-engineering-pristine/$version\"]" '
  $0 == header { in_pristine=1; first=1 }
  in_pristine && !first && /^\[/ { exit }
  in_pristine { print; first=0 }
' "$rendered_externals")
[ -n "$pristine_block" ] || fail "rendered pristine external block missing"
[ "$(grep -c '^\[".local/share/compound-engineering-pristine/' "$rendered_externals")" = 1 ] \
  || fail "expected exactly one pristine external"
printf '%s\n' "$pristine_block" | grep -qxF 'type = "archive"' \
  || fail "pristine external is not an archive"
printf '%s\n' "$pristine_block" | grep -qxF 'exact = true' \
  || fail "pristine external is not exact"
printf '%s\n' "$pristine_block" | grep -qxF 'stripComponents = 1' \
  || fail "pristine external lost stripComponents"
if printf '%s\n' "$pristine_block" | grep -q '^exclude'; then
  fail "pristine external must be include-only"
fi
[ "$(printf '%s\n' "$pristine_block" | grep '^url = ')" = "$(printf '%s\n' "$ce_block" | grep '^url = ')" ] \
  || fail "pristine external does not fetch the same archive as the CE external"
expected_pristine_include="include = $(jq -c '[.paths | keys[] | split("/") as $parts | range(1; ($parts | length) + 1) as $i | "*/" + ($parts[0:$i] | join("/"))] | unique' "$base_json")"
[ "$(printf '%s\n' "$pristine_block" | grep '^include = ')" = "$expected_pristine_include" ] \
  || fail "pristine include list differs from the expected parent directory patterns"

# The base.json keys and each authority's excludes stay one set.
expected_excludes=$(jq -r '.paths | keys[] | "*/" + .' "$base_json" | LC_ALL=C sort)
ce_excludes=$(printf '%s\n' "$ce_block" | sed -n 's/^exclude = //p' | jq -r '.[]' | LC_ALL=C sort)
omp_excludes=$(printf '%s\n' "$omp_ce_block" | sed -n 's/^exclude = //p' | jq -r '.[]' | grep -vxF '*/plugin.json' | LC_ALL=C sort)
[ "$ce_excludes" = "$expected_excludes" ] \
  || fail "CE external excludes are not the base.json key set"
[ "$omp_excludes" = "$expected_excludes" ] \
  || fail "CE-omp external excludes, apart from plugin.json, are not the base.json key set"

# The rendered provisioner embeds the real base.json: the tag and, per key in the
# same order, the pre-image, post-image and mode.
array_lines() { # <array name> -> the quoted elements of the rendered array, one per line
  awk -v name="$1" '$0 == name "=(" { in_array = 1; next } in_array && /^\)/ { exit } in_array { sub(/^ +/, ""); gsub(/"/, ""); print }' "$real_prov"
}
grep -qxF "BASE_TAG=\"$base_tag\"" "$real_prov" || fail "the rendered provisioner does not embed the base.json tag"
[ "$(array_lines PATCH_KEYS)" = "$base_keys" ] || fail "the rendered provisioner's PATCH_KEYS differ from the base.json keys"
[ "$(array_lines POST_SHA)" = "$(jq -r '.paths | to_entries | sort_by(.key)[] | .value.postimage.sha256' "$base_json")" ] \
  || fail "the rendered provisioner's POST_SHA differ from the base.json post-images"
[ "$(array_lines POST_MODE)" = "$(jq -r '.paths | to_entries | sort_by(.key)[] | .value.mode' "$base_json")" ] \
  || fail "the rendered provisioner's POST_MODE differ from the base.json modes"
[ "$(array_lines PRE_SHA)" = "$(jq -r '.paths | to_entries | sort_by(.key)[] | .value.preimage | if . == "absent" then "absent" else .sha256 end' "$base_json")" ] \
  || fail "the rendered provisioner's PRE_SHA differ from the base.json pre-images"
[ "$(array_lines PRE_MODE)" = "$(jq -r '.paths | to_entries | sort_by(.key)[] | .value.preimage | if . == "absent" then "-" else .mode end' "$base_json")" ] \
  || fail "the rendered provisioner's PRE_MODE differ from the base.json pre-image modes"

# Only the two CE copies are apply targets; the pristine tree is never one, and never a marketplace.
target_dirs=$(awk '/^TARGET_DIRS=\(/ { in_targets=1; next } in_targets && /^\)/ { exit } in_targets { print }' "$real_prov")
[ "$(printf '%s\n' "$target_dirs" | grep -c .)" = 2 ] \
  || fail "provisioner TARGET_DIRS should list the two CE copies"
if printf '%s\n' "$target_dirs" | grep -q 'compound-engineering-pristine'; then
  fail "provisioner TARGET_DIRS contain the pristine path"
fi
marketplace_names_tmpl="$scratch/marketplace-names.tmpl"
printf '%s' '{{ range $name, $authority := .agents.marketplaces }}{{ $name }}{{ "\n" }}{{ end }}' > "$marketplace_names_tmpl"
render "$root" "$render_scratch" "$chezmoi_bin" linux "$marketplace_names_tmpl" "$scratch/marketplace-names.out"
if grep -q 'pristine' "$scratch/marketplace-names.out"; then
  fail "the pristine tree is declared as an agents.marketplaces row"
fi

# pristinePath goes through the same safety rule as externalPath.
pristine_override() { printf '{"chezmoi":{"os":"linux"},"agents":{"marketplaces":{"compound-engineering-plugin":{"pristinePath":"%s"}}}}' "$1"; }
render_source_template .chezmoiexternals/ai-agents.toml "$scratch/alt-pristine.toml" "$(pristine_override .local/share/ce-alt-pristine)"
grep -qxF "[\".local/share/ce-alt-pristine/$version\"]" "$scratch/alt-pristine.toml" \
  || fail "a safe pristinePath override did not move the pristine external"
for unsafe_pristine in '../escape' '/abs/path' 'bad path' '.local/../x' '$HOME/x'; do
  for unsafe_template in .chezmoiexternals/ai-agents.toml .chezmoiscripts/70-agents/run_onchange_after_zz-prune-agent-marketplace-archives.sh.tmpl "$provisioner_template"; do
    if render_source_template "$unsafe_template" "$scratch/unsafe.out" "$(pristine_override "$unsafe_pristine")" 2>"$scratch/unsafe.err"; then
      fail "render accepted the unsafe pristinePath '$unsafe_pristine' in $unsafe_template"
    fi
    grep -qF 'unsafe pristinePath' "$scratch/unsafe.err" \
      || fail "render of $unsafe_template failed for '$unsafe_pristine' without naming the unsafe pristinePath"
  done
done

echo "compound-engineering overlays: ok"
