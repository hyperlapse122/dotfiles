#!/usr/bin/env bash
# test-top-level-deployment-boundary.sh — audit the deployment boundary at the
# chezmoi source root (home/) against .ci/top-level-boundary-inventory.yaml.
#
# The chezmoi source state lives under home/ behind .chezmoiroot. This gate
# enforces that repository infrastructure outside home/ cannot deploy to $HOME,
# and that every entry at the source root is accounted for.
#
# FIVE SOURCE-ROOT CHECKS, all bidirectional against the rendered ignore file
# rather than a restatement of it.
#   1. The inventory's key set equals the git-tracked source-root entry set.
#   2. A `source-internal` class is declared for exactly the dot-prefixed names.
#   3. Per profile, every declared verdict matches what chezmoi renders:
#      `repo-only` is ignored everywhere, `deployed` is eligible (narrowed by
#      `only_on`), and a disagreement in either direction fails.
#   4. Per profile, every top-level name the rendered .chezmoiignore
#      carries matches exactly one declared name — no stale entry, no duplicate.
#   5. Default deny: anything sitting at the source root that is not declared
#      deployed must be ignored, tracked or not.
#
# THREE R12 REPOSITORY-ROOT CHECKS:
#   (a) .chezmoiroot exists, holds `home` after whitespace trimming, and
#       `chezmoi source-path` under the render contract equals resolve_source_root.
#   (b) The repository root holds no .chezmoi* entry other than .chezmoiroot and
#       no entry carrying a source-attribute prefix.
#   (c) The hook literal in home/.chezmoi.toml.tmpl has basename
#       .install-prerequisites.sh and directory src/github.com/hyperlapse122/dotfiles;
#       the file exists and is executable at the repository root; no
#       home/.install-prerequisites.sh exists.
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
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
source_root=$(resolve_source_root "$repo_root")

SOURCE_ATTRIBUTE_PREFIXES=(
  dot_
  private_
  symlink_
  remove_
  executable_
  readonly_
  encrypted_
  create_
  modify_
  run_
  exact_
  literal_
  empty_
  once_
  onchange_
  before_
  after_
)

check_chezmoiroot() {
  local root=$1 scratch_dir=$2 chezmoi_cmd=$3
  local marker="$root/.chezmoiroot"
  [[ -f "$marker" ]] || { printf '%s\n' ".chezmoiroot is missing in $root" >&2; return 1; }
  local content
  content=$(tr -d '[:space:]' <"$marker")
  [[ "$content" == "home" ]] || {
    printf '%s\n' ".chezmoiroot in $root must contain 'home', got '$content'" >&2
    return 1
  }
  local resolved expected
  resolved=$(resolve_source_root "$root") || return 1
  expected=$(
    PATH="$scratch_dir/bin:/usr/bin:/bin" "$chezmoi_cmd" \
      --config "$scratch_dir/empty.toml" \
      --source "$root" \
      --destination "$scratch_dir/target" \
      source-path
  ) || { printf '%s\n' "chezmoi source-path failed for $root" >&2; return 1; }
  [[ "$resolved" == "$expected" ]] || {
    printf '%s\n' "chezmoi source-path ($expected) does not match resolve_source_root ($resolved) for $root" >&2
    return 1
  }
}

check_repo_root_entries() {
  local root=$1
  local failures=()
  local entry prefix
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ "$entry" == .chezmoi* && "$entry" != ".chezmoiroot" ]]; then
      failures+=("repository root contains stray chezmoi input '$entry'; chezmoi inputs must live under the source root")
    fi
    for prefix in "${SOURCE_ATTRIBUTE_PREFIXES[@]}"; do
      if [[ "$entry" == "$prefix"* ]]; then
        failures+=("repository root contains source-attribute-prefixed entry '$entry'; source state must live under the source root")
        break
      fi
    done
  done < <(find "$root" -mindepth 1 -maxdepth 1 -printf '%f\n')

  if [[ ${#failures[@]} -gt 0 ]]; then
    for f in "${failures[@]}"; do
      printf '%s\n' "$f" >&2
    done
    return 1
  fi
  return 0
}

check_hook_location_and_literal() {
  local root=$1 source_dir=$2
  local config_tmpl="$source_dir/.chezmoi.toml.tmpl"
  [[ -f "$config_tmpl" ]] || { printf '%s\n' "missing $config_tmpl" >&2; return 1; }

  local hook_literal
  hook_literal=$(sed -n -E 's/^[[:space:]]*script[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$config_tmpl")
  [[ -n "$hook_literal" ]] || { printf '%s\n' "failed to find hook script literal in $config_tmpl" >&2; return 1; }

  local hook_base hook_dir
  hook_base=$(basename "$hook_literal")
  hook_dir=$(dirname "$hook_literal")

  [[ "$hook_base" == ".install-prerequisites.sh" ]] || {
    printf '%s\n' "hook literal basename must be '.install-prerequisites.sh', got '$hook_base'" >&2
    return 1
  }
  [[ "$hook_dir" == "src/github.com/hyperlapse122/dotfiles" ]] || {
    printf '%s\n' "hook literal directory must be 'src/github.com/hyperlapse122/dotfiles', got '$hook_dir'" >&2
    return 1
  }

  local hook_file="$root/$hook_base"
  [[ -f "$hook_file" ]] || {
    printf '%s\n' "hook script $hook_file is missing at repository root" >&2
    return 1
  }
  [[ -x "$hook_file" ]] || {
    printf '%s\n' "hook script $hook_file at repository root is not executable" >&2
    return 1
  }

  local stray_hook="$source_dir/$hook_base"
  if [[ -e "$stray_hook" ]]; then
    printf '%s\n' "hook script must not exist under source root, found $stray_hook" >&2
    return 1
  fi
  return 0
}


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

argv: <inventory.yaml> <tracked-list> <verdicts-tsv> <rendered-index-tsv> <present-list>

tracked-list      one git-tracked top-level name per line
verdicts-tsv      <profile>\t<entry>\t<ignored|eligible>, measured per profile
rendered-index    <profile>\t<path to that profile's rendered .chezmoiignore>
present-list      one non-dot top-level name per line that exists on disk
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
    inventory_path, tracked_path, verdicts_path, rendered_path, present_path = sys.argv[1:6]

    doc = yaml.safe_load(pathlib.Path(inventory_path).read_text(encoding="utf-8")) or {}
    entries = doc.get("entries") or {}
    preemptive = doc.get("preemptive_denials") or []
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
    present = [
        line for line in pathlib.Path(present_path).read_text(encoding="utf-8").splitlines() if line
    ]

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
    declared = set(entries) | set(preemptive)
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

    # 5. Default deny. Anything sitting at the source root that the inventory does
    #    not declare deployed must be ignored, whether or not git tracks it.
    #    This is the check that needs no list: a generated directory nobody
    #    thought to declare is caught because it is there, not because someone
    #    remembered it.
    undeclared = [name for name in present if name not in entries]
    for profile in profiles:
        path = rendered.get(profile)
        if path is None:
            continue
        denied = set(top_level_patterns(path))
        for name in sorted(undeclared):
            if name not in denied:
                failures.append(
                    f"{name} sits at the source root, is declared nowhere, and profile "
                    f"{profile} does not ignore it, so it would deploy into $HOME; deny it "
                    f"in .chezmoiignore, or declare it in the inventory if it belongs there"
                )

    # A preemptive denial only suppresses the stale report in check 4, because the
    # path it names may legitimately be absent from a clean checkout. It carries no
    # safety obligation: check 5 already covers the path whenever it is present.
    for name in sorted(preemptive):
        if name in entries:
            failures.append(
                f"{name} is listed in preemptive_denials but also in entries; a tracked "
                f"entry is never absent, so its denial can never read as stale"
            )
        if not any(
            name in set(top_level_patterns(path))
            for path in (rendered.get(profile) for profile in profiles)
            if path is not None
        ):
            failures.append(
                f"{name} is listed in preemptive_denials but no profile denies it; drop "
                f"the listing or add the .chezmoiignore line it exists to explain"
            )

    return report(failures)


sys.exit(main())
PYTHON

run_checker() {
  "$gate_python" "$checker" "$@"
}

# --- Measure the real tree ---------------------------------------------------

tracked_list="$scratch/tracked"
source_rel=${source_root#"$repo_root"/}
if [[ "$source_root" == "$repo_root" ]]; then
  git -C "$repo_root" ls-tree --name-only HEAD >"$tracked_list"
else
  git -C "$repo_root" ls-tree --name-only "HEAD:$source_rel" >"$tracked_list"
fi
[[ -s $tracked_list ]] || fail 'git ls-tree returned no entries for source root'

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
out.joinpath("preemptive.txt").write_text("".join(
    name + "\n" for name in (doc.get("preemptive_denials") or [])
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

# Every non-dot name actually sitting at the source root. chezmoi reads the
# directory, not the index, so this -- not `git ls-files` -- is what it sees.
present_list="$scratch/present"
find "$source_root" -mindepth 1 -maxdepth 1 -printf '%f\n' |
  grep -v '^\.' | LC_ALL=C sort >"$present_list"

run_checker "$inventory" "$tracked_list" "$verdicts" "$rendered_index" "$present_list" ||
  fail 'this repository has source-root deployment-boundary drift (listed above)'
pass 'every source-root entry matches its declared verdict across all profiles'

check_chezmoiroot "$repo_root" "$scratch" "$chezmoi_bin" ||
  fail 'R12 (a) failed: .chezmoiroot content or chezmoi source-path parity check failed'
pass 'R12 (a): .chezmoiroot holds home and chezmoi source-path matches resolve_source_root'

check_repo_root_entries "$repo_root" ||
  fail 'R12 (b) failed: repository root contains stray chezmoi inputs or source-attribute-prefixed entries'
pass 'R12 (b): repository root contains no stray chezmoi inputs or source-prefixed entries'

check_hook_location_and_literal "$repo_root" "$source_root" ||
  fail 'R12 (c) failed: hook location or literal check failed'
pass 'R12 (c): hook script is at repository root, executable, and correctly referenced'

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
preemptive_denials:
  - lock.generated
YAML
  } >"$tree/inventory.yaml"
  printf '.ci\nREADME.md\nLibrary\ndot_zshenv\n' >"$tree/tracked"
  # What check 5 enumerates: the non-dot names sitting at the source root. The
  # generated one is present here and absent from `tracked`, which is the case
  # the tracked-only view cannot see.
  printf 'README.md\nLibrary\ndot_zshenv\nlock.generated\n' >"$tree/present"
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
  printf '%s' "$tree"
}

check_fixture() {
  local tree=$1
  run_checker "$tree/inventory.yaml" "$tree/tracked" "$tree/verdicts" "$tree/index" "$tree/present"
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

# Check 5, the one that needs no list: a path sitting at the source root that no
# profile denies would deploy, whether or not git tracks it and whether or not
# anyone declared it.
undenied_present=$(fixture undenied-present)
printf './README.md\n./Library\n' >"$undenied_present/rendered-linux-gnome"
expect_reject "$undenied_present" 'an undeclared path at the source root that is not denied fails' \
  'lock.generated sits at the source root, is declared nowhere, and profile linux-gnome does not ignore it'

# The same check with nothing declared about it at all -- the shape a new tool
# creates when it starts writing into the source root and nobody notices.
undeclared_present=$(fixture undeclared-present)
printf 'README.md\nLibrary\ndot_zshenv\nlock.generated\nbuild-out\n' >"$undeclared_present/present"
expect_reject "$undeclared_present" 'a brand-new path nobody declared fails without any list' \
  'build-out sits at the source root, is declared nowhere, and profile linux-gnome does not ignore it'

# A preemptive denial that guards nothing is itself drift.
orphan_preemptive=$(fixture orphan-preemptive)
for id in "${fixture_profiles[@]}"; do
  printf './README.md\n./Library\n' >"$orphan_preemptive/rendered-$id"
done
printf 'README.md\nLibrary\ndot_zshenv\n' >"$orphan_preemptive/present"
expect_reject "$orphan_preemptive" 'a preemptive denial no profile carries fails' \
  'lock.generated is listed in preemptive_denials but no profile denies it'

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

# Stale AGENTS.md denial mutant:
stale_agents=$(fixture stale-agents)
printf './AGENTS.md\n./README.md\n./Library\n./lock.generated\n' >"$stale_agents/rendered-linux-gnome"
expect_reject "$stale_agents" 'a stale denial for AGENTS.md fails' \
  '.chezmoiignore denies AGENTS.md in profile linux-gnome, which matches no declared top-level entry'

# R12 (a) mutants:
fx_missing_root="$scratch/fx-missing-root"
mkdir -p -- "$fx_missing_root"
report="$scratch/report-missing-root"
if check_chezmoiroot "$fx_missing_root" "$scratch" "$chezmoi_bin" >"$report" 2>&1; then
  fail 'missing .chezmoiroot was accepted'
fi
grep -qF '.chezmoiroot is missing' "$report" || fail "missing .chezmoiroot rejected for wrong reason: $(cat "$report")"
pass 'R12 (a) mutant: missing .chezmoiroot fails'

fx_wrong_root="$scratch/fx-wrong-root"
mkdir -p -- "$fx_wrong_root"
printf 'src\n' >"$fx_wrong_root/.chezmoiroot"
report="$scratch/report-wrong-root"
if check_chezmoiroot "$fx_wrong_root" "$scratch" "$chezmoi_bin" >"$report" 2>&1; then
  fail '.chezmoiroot holding src was accepted'
fi
grep -qF "must contain 'home', got 'src'" "$report" ||
  fail "wrong .chezmoiroot rejected for wrong reason: $(cat "$report")"
pass "R12 (a) mutant: .chezmoiroot holding src fails naming expected value 'home'"

# R12 (b) mutants (AE5):
fx_stray_data="$scratch/fx-stray-data"
mkdir -p -- "$fx_stray_data/.chezmoidata"
report="$scratch/report-stray-data"
if check_repo_root_entries "$fx_stray_data" >"$report" 2>&1; then
  fail 'stray .chezmoidata at repository root was accepted'
fi
grep -qF "repository root contains stray chezmoi input '.chezmoidata'" "$report" ||
  fail "stray .chezmoidata rejected for wrong reason: $(cat "$report")"
pass 'R12 (b) mutant (AE5): stray .chezmoidata at repository root fails'

fx_stray_dot="$scratch/fx-stray-dot"
mkdir -p -- "$fx_stray_dot"
touch "$fx_stray_dot/dot_example"
report="$scratch/report-stray-dot"
if check_repo_root_entries "$fx_stray_dot" >"$report" 2>&1; then
  fail 'stray dot_example at repository root was accepted'
fi
grep -qF "repository root contains source-attribute-prefixed entry 'dot_example'" "$report" ||
  fail "stray dot_example rejected for wrong reason: $(cat "$report")"
pass 'R12 (b) mutant (AE5): stray dot_example at repository root fails'

# R12 (c) mutant:
fx_stray_hook_root="$scratch/fx-stray-hook-root"
mkdir -p -- "$fx_stray_hook_root/home"
touch "$fx_stray_hook_root/.install-prerequisites.sh"
chmod 755 "$fx_stray_hook_root/.install-prerequisites.sh"
touch "$fx_stray_hook_root/home/.install-prerequisites.sh"
cat <<'EOF' >"$fx_stray_hook_root/home/.chezmoi.toml.tmpl"
[hooks.read-source-state.pre]
    script = "src/github.com/hyperlapse122/dotfiles/.install-prerequisites.sh"
EOF
report="$scratch/report-stray-hook"
if check_hook_location_and_literal "$fx_stray_hook_root" "$fx_stray_hook_root/home" >"$report" 2>&1; then
  fail 'hook copied under home/ was accepted'
fi
grep -qF 'hook script must not exist under source root' "$report" ||
  fail "stray hook under home/ rejected for wrong reason: $(cat "$report")"
pass 'R12 (c) mutant: hook copied under home/ fails'

printf 'test-top-level-deployment-boundary: all tests passed\n'
