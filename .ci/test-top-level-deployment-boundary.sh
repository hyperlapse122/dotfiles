#!/usr/bin/env bash
# test-top-level-deployment-boundary.sh — audit the repository's top-level
# deployment boundary against .ci/top-level-boundary-inventory.yaml.
#
# AGENTS.md states the rule this enforces: "Dot-prefixed source paths are
# internal; non-dot metadata (AGENTS.md, LICENSE) MUST be listed in the root
# .chezmoiignore." Nothing checked it. Its failure mode is silent in a green run
# and loud on a real host: a new non-dot top-level entry nobody remembered to
# deny is deployed into $HOME, and the reverse — a denial whose file moved or
# was renamed — leaves the list quietly disagreeing with the tree.
#
# FOUR CHECKS, all bidirectional against the rendered ignore file rather than a
# restatement of it.
#   1. The inventory's key set equals the git-tracked top-level entry set.
#   2. A `source-internal` class is declared for exactly the dot-prefixed names.
#   3. Per profile, every declared verdict matches what chezmoi renders:
#      `repo-only` is ignored everywhere, `deployed` is eligible (narrowed by
#      `only_on`), and a disagreement in either direction fails.
#   4. Per profile, every top-level name the rendered .chezmoiignore
#      carries matches exactly one declared name — no stale entry, no duplicate.
#
# Plus the two obligations `generated_in_source` owes: those names are untracked,
# so check 1 cannot see them, yet they are written into the source directory
# where chezmoi can. Each must be covered by .gitignore AND by .chezmoiignore.
#
# What divides this gate from .ci/test-chezmoiignore-script-paths.sh is whether a
# rendered pattern can match a ROOT-level target. A bare name can, and so do the
# directory-only `name/` and recursive `**/name` spellings; all three are this
# gate's business. A pattern addressing a path under a top-level entry is that
# gate's (and the other render gates') business, not this one's.
#
# Renders go through .ci/lib/render-gate-helpers.sh because AGENTS.md requires a
# CI gate to use its render() rather than hand-roll the scratch/op-stub/empty
# config/throwaway destination contract.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() { printf 'test-top-level-boundary: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'test-top-level-boundary: ok - %s\n' "$*"; }

# shellcheck source=.ci/lib/render-scratch.sh
source "$repo_root/.ci/lib/render-scratch.sh"
setup_render_scratch top-level-boundary
mkdir -p -- "$scratch/home"
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"

chezmoi_bin=$(command -v chezmoi) || fail 'chezmoi is not on PATH'

inventory="$repo_root/.ci/top-level-boundary-inventory.yaml"
[[ -f $inventory ]] || fail "missing $inventory"

# The repo's other Python-using gates probe /usr/bin/python3 first because a mise
# or pyenv interpreter earlier on PATH usually lacks the distro modules.
gate_python=''
for candidate in /usr/bin/python3 python3; do
  command -v "$candidate" >/dev/null 2>&1 || continue
  if "$candidate" -c 'import yaml' >/dev/null 2>&1; then
    gate_python=$candidate
    break
  fi
done
[[ -n $gate_python ]] ||
  fail 'no python3 with PyYAML found; install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)'

# Source name to target path, per AGENTS.md "Source layout and attributes".
# Declaring the target in the inventory instead would be a second copy of this
# transform to keep in sync.
target_of() {
  local name=${1%.tmpl}
  while :; do
    case $name in
      private_*) name=${name#private_} ;;
      readonly_*) name=${name#readonly_} ;;
      executable_*) name=${name#executable_} ;;
      symlink_*) name=${name#symlink_} ;;
      remove_*) name=${name#remove_} ;;
      encrypted_*) name=${name#encrypted_} ;;
      *) break ;;
    esac
  done
  case $name in dot_*) name=".${name#dot_}" ;; esac
  printf '%s' "$name"
}

checker="$scratch/check_boundary.py"
cat <<'PYTHON' >"$checker"
"""Report top-level deployment-boundary drift.

argv: <inventory.yaml> <tracked-list> <verdicts-tsv> <rendered-index-tsv> <gitignored-list>

tracked-list      one git-tracked top-level name per line
verdicts-tsv      <profile>\t<entry>\t<ignored|eligible>, measured per profile
rendered-index    <profile>\t<path to that profile's rendered .chezmoiignore>
gitignored-list   one generated_in_source name per line that .gitignore covers
"""
import pathlib
import sys

import yaml

CLASSES = {"source-internal", "repo-only", "deployed"}

# Every per-profile check loops over the inventory's profile list, so the list is
# pinned here rather than trusted: an emptied or thinned list would otherwise
# switch the gate off while it still reported green.
REQUIRED_PROFILES = {
    "linux-gnome",
    "linux-kde",
    "linux-headless",
    "linux-jetson",
    "linux-container",
    "macos",
}


def report(failures):
    for line in failures:
        print(line, file=sys.stderr)
    return 1 if failures else 0


def root_target(pattern):
    """The top-level name a rendered ignore pattern can match, else None.

    A bare name addresses a top-level entry directly. Two further shapes still
    reach a root-level target and would otherwise slip past a plain "has a
    slash" test: a directory-only trailing slash (`name/`) and a leading
    recursive segment (`**/name`). Anything else addresses a path *under* a
    top-level entry, which is the script-path gate's business, not this one's.
    """
    if pattern.startswith("./"):
        pattern = pattern[2:]
    if pattern.startswith("**/"):
        pattern = pattern[3:]
    if pattern.endswith("/"):
        pattern = pattern[:-1]
    if not pattern or "/" in pattern:
        return None
    return pattern


def top_level_patterns(path):
    """Every top-level name the rendered ignore file denies, in file order.

    Order is preserved so a duplicate is reported where a reader would meet it.
    Two spellings of the same name (`docs` and `docs/`) normalize to one name
    and therefore read as the duplicate they are.
    """
    out = []
    for raw in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        pattern = raw.strip()
        if not pattern or pattern.startswith("#"):
            continue
        name = root_target(pattern)
        if name is not None:
            out.append(name)
    return out


def main():
    inventory_path, tracked_path, verdicts_path, rendered_path, gitignored_path = sys.argv[1:6]

    doc = yaml.safe_load(pathlib.Path(inventory_path).read_text(encoding="utf-8")) or {}
    entries = doc.get("entries") or {}
    generated = doc.get("generated_in_source") or []
    profiles = [p["id"] for p in (doc.get("profiles") or [])]

    if len(profiles) != len(set(profiles)):
        return report([
            "the inventory declares a profile id more than once; every profile "
            "must appear exactly once in .ci/top-level-boundary-inventory.yaml"
        ])
    if set(profiles) != REQUIRED_PROFILES:
        missing = sorted(REQUIRED_PROFILES - set(profiles))
        extra = sorted(set(profiles) - REQUIRED_PROFILES)
        return report([
            "the inventory's profile set does not match the canonical set; "
            f"missing {missing or 'nothing'}, unexpected {extra or 'nothing'}. "
            "Every per-profile check loops over this list, so a thinned list "
            "silently stops checking."
        ])

    tracked = [
        line for line in pathlib.Path(tracked_path).read_text(encoding="utf-8").splitlines() if line
    ]
    gitignored = {
        line for line in pathlib.Path(gitignored_path).read_text(encoding="utf-8").splitlines() if line
    }

    verdicts = {}
    for line in pathlib.Path(verdicts_path).read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        profile, entry, verdict = line.split("\t")
        verdicts[(profile, entry)] = verdict

    rendered = {}
    for line in pathlib.Path(rendered_path).read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        profile, path = line.split("\t")
        rendered[profile] = path

    failures = []

    # 1. Inventory key set equals the tracked top-level set.
    for name in sorted(set(tracked) - set(entries)):
        failures.append(
            f"{name} is tracked at the top level but absent from the inventory; "
            f"add it to .ci/top-level-boundary-inventory.yaml with its class"
        )
    for name in sorted(set(entries) - set(tracked)):
        failures.append(
            f"{name} is declared in the inventory but is not a tracked top-level entry; "
            f"drop it from .ci/top-level-boundary-inventory.yaml"
        )

    # 2. source-internal is declared for exactly the dot-prefixed names.
    for name, spec in sorted(entries.items()):
        klass = (spec or {}).get("class")
        if klass not in CLASSES:
            failures.append(
                f"{name} declares class {klass!r}, which is not one of "
                f"{', '.join(sorted(CLASSES))}; fix .ci/top-level-boundary-inventory.yaml"
            )
            continue
        dotted = name.startswith(".")
        if dotted and klass != "source-internal":
            failures.append(
                f"{name} starts with a dot, so chezmoi ignores it outright, but the "
                f"inventory declares it {klass}; declare it source-internal"
            )
        if not dotted and klass == "source-internal":
            failures.append(
                f"{name} does not start with a dot, so chezmoi reads it, but the "
                f"inventory declares it source-internal; declare it repo-only or deployed"
            )
        only_on = (spec or {}).get("only_on")
        if only_on is not None:
            unknown = sorted(set(only_on) - REQUIRED_PROFILES)
            if unknown:
                failures.append(
                    f"{name} narrows only_on to {unknown}, which are not profile ids; "
                    f"an unknown id silently makes the entry ignored everywhere"
                )

    # 3. Declared verdict matches the rendered verdict, per profile.
    for profile in profiles:
        for name, spec in sorted(entries.items()):
            spec = spec or {}
            if spec.get("class") == "source-internal":
                continue
            only_on = spec.get("only_on")
            deploys_here = spec.get("class") == "deployed" and (
                only_on is None or profile in only_on
            )
            expected = "eligible" if deploys_here else "ignored"
            measured = verdicts.get((profile, name))
            if measured is None:
                failures.append(
                    f"{name} has no measured verdict in profile {profile}; the gate "
                    f"did not render that profile"
                )
            elif measured != expected:
                if expected == "ignored":
                    failures.append(
                        f"{name} is declared {spec.get('class')} but profile {profile} "
                        f"does not ignore it, so it would deploy into $HOME; add it to "
                        f".chezmoiignore or change its class"
                    )
                else:
                    failures.append(
                        f"{name} is declared deployed but profile {profile} ignores it; "
                        f"remove the .chezmoiignore entry or narrow the class with only_on"
                    )

    # 4. Every denied top-level name matches exactly one declared entry.
    declared = set(entries) | set(generated)
    for profile in profiles:
        path = rendered.get(profile)
        if path is None:
            failures.append(f"profile {profile} was never rendered")
            continue
        seen = {}
        for pattern in top_level_patterns(path):
            seen[pattern] = seen.get(pattern, 0) + 1
            if seen[pattern] == 2:
                failures.append(
                    f".chezmoiignore denies {pattern} more than once in profile {profile}; "
                    f"remove the duplicate line"
                )
        for pattern in sorted(seen):
            if pattern not in declared:
                failures.append(
                    f".chezmoiignore denies {pattern} in profile {profile}, which matches "
                    f"no declared top-level entry; delete the stale line or declare the entry"
                )

    # generated_in_source owes both obligations.
    for name in sorted(generated):
        if name in entries:
            failures.append(
                f"{name} is listed in generated_in_source but also in entries; "
                f"generated_in_source is for untracked paths only"
            )
        if name not in gitignored:
            failures.append(
                f"{name} is listed in generated_in_source but .gitignore does not cover it; "
                f"add it to .gitignore"
            )
        for profile in profiles:
            path = rendered.get(profile)
            if path is None:
                continue
            if name not in top_level_patterns(path):
                failures.append(
                    f"{name} is generated inside the source directory but profile {profile} "
                    f"does not ignore it, so it would deploy into $HOME; add it to .chezmoiignore"
                )

    return report(failures)


sys.exit(main())
PYTHON

run_checker() {
  "$gate_python" "$checker" "$@"
}

# --- Measure the real tree ---------------------------------------------------

tracked_list="$scratch/tracked"
git -C "$repo_root" ls-tree --name-only HEAD >"$tracked_list"
[[ -s $tracked_list ]] || fail 'git ls-tree returned no top-level entries'

"$gate_python" -c '
import pathlib, sys, yaml
doc = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
out = pathlib.Path(sys.argv[2])
out.joinpath("profiles.tsv").write_text("".join(
    "\t".join([p["id"], p["os"], p["desktop"], str(p["container"]).lower(), str(p["jetson"]).lower()]) + "\n"
    for p in doc["profiles"]
), encoding="utf-8")
out.joinpath("audited.txt").write_text("".join(
    name + "\n"
    for name, spec in (doc.get("entries") or {}).items()
    if (spec or {}).get("class") != "source-internal"
), encoding="utf-8")
out.joinpath("generated.txt").write_text("".join(
    name + "\n" for name in (doc.get("generated_in_source") or [])
), encoding="utf-8")
' "$inventory" "$scratch"

# The target a source name maps to does not vary by profile, so resolve it once.
audited_targets="$scratch/audited-targets"
: >"$audited_targets"
while IFS= read -r entry; do
  [[ -n $entry ]] || continue
  printf '%s\t%s\n' "$entry" "$(target_of "$entry")" >>"$audited_targets"
done <"$scratch/audited.txt"

rendered_index="$scratch/rendered-index"
verdicts="$scratch/verdicts"
: >"$rendered_index"
: >"$verdicts"

while IFS=$'\t' read -r id os desktop container jetson; do
  [[ -n $id ]] || continue
  out="$scratch/rendered-$id"
  render_ignore "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$container" "$out" "$jetson" "$desktop"
  printf '%s\t%s\n' "$id" "$out" >>"$rendered_index"
  while IFS=$'\t' read -r entry target; do
    [[ -n $entry ]] || continue
    if is_ignored "$repo_root" "$scratch" "$chezmoi_bin" "$out" "$target"; then
      printf '%s\t%s\t%s\n' "$id" "$entry" ignored >>"$verdicts"
    else
      printf '%s\t%s\t%s\n' "$id" "$entry" eligible >>"$verdicts"
    fi
  done <"$audited_targets"
done <"$scratch/profiles.tsv"

gitignored="$scratch/gitignored"
: >"$gitignored"
while IFS= read -r name; do
  [[ -n $name ]] || continue
  # Ask about both forms: a directory-only .gitignore pattern (`_artifacts/`)
  # does not match the bare name when the path is absent from the checkout.
  if git -C "$repo_root" check-ignore -q -- "$name" ||
    git -C "$repo_root" check-ignore -q -- "$name/"; then
    printf '%s\n' "$name" >>"$gitignored"
  fi
done <"$scratch/generated.txt"

run_checker "$inventory" "$tracked_list" "$verdicts" "$rendered_index" "$gitignored" ||
  fail 'this repository has top-level deployment-boundary drift (listed above)'
pass 'every top-level entry matches its declared verdict across all profiles'

# --- Fixtures: prove the gate would notice -----------------------------------
#
# The check above only proves the current tree is clean. These fixtures prove it
# would fail if it were not — the same mutant discipline .ci/test-ci-wiring.sh
# and .ci/test-chezmoiignore-script-paths.sh use.

# The canonical profile ids, mirrored from the checker so a fixture exercises the
# same set the real inventory must declare.
fixture_profiles=(linux-gnome linux-kde linux-headless linux-jetson linux-container macos)

fixture() {
  local name=$1 tree="$scratch/fx-$1" id
  mkdir -p -- "$tree"
  {
    printf 'profiles:\n'
    for id in "${fixture_profiles[@]}"; do
      printf '  - { id: %s, os: linux, desktop: gnome, container: false, jetson: false }\n' "$id"
    done
    cat <<'YAML'
entries:
  .ci: { class: source-internal }
  README.md: { class: repo-only }
  Library: { class: deployed, only_on: [macos] }
  dot_zshenv: { class: deployed }
generated_in_source:
  - lock.generated
YAML
  } >"$tree/inventory.yaml"
  printf '.ci\nREADME.md\nLibrary\ndot_zshenv\n' >"$tree/tracked"
  : >"$tree/verdicts"
  : >"$tree/index"
  for id in "${fixture_profiles[@]}"; do
    # Library is deployed on macos only, so only that profile leaves it eligible
    # and only the others deny it.
    if [[ $id == macos ]]; then
      printf './README.md\n./lock.generated\n.config/thing\n' >"$tree/rendered-$id"
      printf '%s\tLibrary\teligible\n' "$id" >>"$tree/verdicts"
    else
      printf './README.md\n./Library\n./lock.generated\n.config/thing\n' >"$tree/rendered-$id"
      printf '%s\tLibrary\tignored\n' "$id" >>"$tree/verdicts"
    fi
    printf '%s\tREADME.md\tignored\n%s\tdot_zshenv\teligible\n' "$id" "$id" >>"$tree/verdicts"
    printf '%s\t%s/rendered-%s\n' "$id" "$tree" "$id" >>"$tree/index"
  done
  printf 'lock.generated\n' >"$tree/gitignored"
  printf '%s' "$tree"
}

check_fixture() {
  local tree=$1
  run_checker "$tree/inventory.yaml" "$tree/tracked" "$tree/verdicts" "$tree/index" "$tree/gitignored"
}

expect_reject() {
  local tree=$1 label=$2 want=$3 report="$scratch/report"
  if check_fixture "$tree" >"$report" 2>&1; then
    fail "$label was accepted; the gate does not detect it"
  fi
  grep -qF "$want" "$report" ||
    fail "$label was rejected for the wrong reason: $(tr '\n' ';' <"$report")"
  pass "$label"
}

baseline=$(fixture baseline)
check_fixture "$baseline" >/dev/null 2>&1 || fail 'the fixture baseline should pass before it is mutated'
pass 'a clean fixture passes'

undeclared=$(fixture undeclared)
printf 'NEWTHING.md\n' >>"$undeclared/tracked"
expect_reject "$undeclared" 'a tracked entry missing from the inventory fails' \
  'NEWTHING.md is tracked at the top level but absent from the inventory'

exposed=$(fixture exposed)
sed 's/^linux-gnome\tREADME.md\tignored$/linux-gnome\tREADME.md\teligible/' \
  "$exposed/verdicts" >"$exposed/verdicts.new" && mv "$exposed/verdicts.new" "$exposed/verdicts"
expect_reject "$exposed" 'a repo-only entry the render does not ignore fails' \
  'README.md is declared repo-only but profile linux-gnome does not ignore it'

withheld=$(fixture withheld)
sed 's/^linux-gnome\tdot_zshenv\teligible$/linux-gnome\tdot_zshenv\tignored/' \
  "$withheld/verdicts" >"$withheld/verdicts.new" && mv "$withheld/verdicts.new" "$withheld/verdicts"
expect_reject "$withheld" 'a deployed entry the render ignores fails' \
  'dot_zshenv is declared deployed but profile linux-gnome ignores it'

stale=$(fixture stale)
printf './README.md\n./Library\n./lock.generated\n./gone\n' >"$stale/rendered-linux-gnome"
expect_reject "$stale" 'a denial matching no declared entry fails' \
  '.chezmoiignore denies gone in profile linux-gnome, which matches no declared top-level entry'

duplicate=$(fixture duplicate)
printf './README.md\n./Library\n./lock.generated\n./README.md\n' >"$duplicate/rendered-linux-gnome"
expect_reject "$duplicate" 'a duplicated denial fails' \
  '.chezmoiignore denies README.md more than once in profile linux-gnome'

# A denial can reach a root-level target without being a bare name. These two
# spellings would slip past a plain "has a slash" test.
stale_dir_form=$(fixture stale-dir-form)
printf './README.md\n./Library\n./lock.generated\ngone/\n' >"$stale_dir_form/rendered-linux-gnome"
expect_reject "$stale_dir_form" 'a stale denial written as a directory pattern fails' \
  '.chezmoiignore denies gone in profile linux-gnome, which matches no declared top-level entry'

stale_recursive_form=$(fixture stale-recursive-form)
printf './README.md\n./Library\n./lock.generated\n**/gone\n' >"$stale_recursive_form/rendered-linux-gnome"
expect_reject "$stale_recursive_form" 'a stale denial written as a recursive pattern fails' \
  '.chezmoiignore denies gone in profile linux-gnome, which matches no declared top-level entry'

# Two spellings of one name are the duplicate they look like.
duplicate_mixed_form=$(fixture duplicate-mixed-form)
printf './README.md\nREADME.md/\n./Library\n./lock.generated\n' >"$duplicate_mixed_form/rendered-linux-gnome"
expect_reject "$duplicate_mixed_form" 'the same name denied in two spellings fails' \
  '.chezmoiignore denies README.md more than once in profile linux-gnome'

unignored_generated=$(fixture unignored-generated)
printf './README.md\n./Library\n' >"$unignored_generated/rendered-linux-gnome"
expect_reject "$unignored_generated" 'a generated-in-source path the render does not ignore fails' \
  'lock.generated is generated inside the source directory but profile linux-gnome does not ignore it'

uncommitted_generated=$(fixture uncommitted-generated)
: >"$uncommitted_generated/gitignored"
expect_reject "$uncommitted_generated" 'a generated-in-source path .gitignore does not cover fails' \
  'lock.generated is listed in generated_in_source but .gitignore does not cover it'

# An inventory that thins its own profile list would otherwise switch off every
# per-profile check while still reporting green.
thinned=$(fixture thinned)
grep -v 'id: linux-kde' "$thinned/inventory.yaml" >"$thinned/inventory.new" &&
  mv "$thinned/inventory.new" "$thinned/inventory.yaml"
expect_reject "$thinned" 'an inventory dropping a profile fails' \
  "the inventory's profile set does not match the canonical set"

unknown_only_on=$(fixture unknown-only-on)
sed 's/only_on: \[macos\]/only_on: [mac-os]/' "$unknown_only_on/inventory.yaml" \
  >"$unknown_only_on/inventory.new" && mv "$unknown_only_on/inventory.new" "$unknown_only_on/inventory.yaml"
expect_reject "$unknown_only_on" 'an only_on naming no real profile fails' \
  "Library narrows only_on to ['mac-os'], which are not profile ids"

# target_of decides which path each entry is measured at. A regression there is
# silent for a `deployed` entry -- the wrong path matches no denial, reads
# eligible, and that is what `deployed` is expected to be -- so assert the
# transform directly rather than only through the tree.
assert_target() {
  local source_name=$1 want=$2 got
  got=$(target_of "$source_name")
  [[ $got == "$want" ]] || fail "target_of $source_name gave '$got', expected '$want'"
}

assert_target dot_zshenv .zshenv
assert_target dot_androidrc.tmpl .androidrc
assert_target private_dot_gnupg .gnupg
assert_target private_readonly_dot_mcp.json.tmpl .mcp.json
assert_target symlink_dot_face.icon .face.icon
assert_target remove_dot_gitconfig .gitconfig
assert_target AGENTS.md AGENTS.md
assert_target Library Library
pass 'target_of maps every source-name prefix form to its target path'

printf 'test-top-level-deployment-boundary: all tests passed\n'
