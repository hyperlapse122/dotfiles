#!/usr/bin/env bash
set -euo pipefail

# The CI suite used to be one job, so a new `.ci` gate had one obvious place to
# go and the `delivery` aggregate had one obvious line to grow. Splitting that
# job into concern-named jobs removes both of those obvious places, and neither
# omission is visible in a green run: a gate script nothing invokes never fails,
# and a job missing from `delivery`'s `needs` never turns the required check red.
# This gate closes both, and it exists because one of them had already happened —
# `.ci/test-garden-shallow-pull.sh` was written and wired nowhere.
#
# TWO CHECKS.
#   1. Every executable `.ci/test-*.sh` and `.ci/check-*.sh` is invoked by some
#      workflow, or by another `.ci` script (a helper reached through its caller
#      is wired), or is a declared exception below.
#   2. Every job in `.github/workflows/ci.yml` appears in `delivery`'s `needs`.
#      `delivery` itself is exempt: a job cannot depend on itself.
#
# Check 1 scans EVERY workflow, not just `ci.yml`. Five gates run only in
# `render-dotfiles.yml` and one only in `merge-commit-only.yml`; a ci.yml-only
# scan would report all six as violations. Check 2 stays ci.yml-scoped because
# that is where `delivery` lives.
#
# Workflows are parsed as YAML rather than grepped: a job id and a `needs` list
# are structure, and a text scan cannot tell a commented-out job from a real one.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/ci-wiring
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

fail() {
  printf 'test-ci-wiring: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'test-ci-wiring: ok - %s\n' "$*"
}

# Scripts CI deliberately does not run, each with the reason it cannot. An entry
# naming a file that no longer exists is itself a failure: a rename would
# otherwise leave the new name silently unguarded.
declare -A exceptions=(
  [test-garden-shallow-pull.sh]='drives the garden CLI against real clones; no runner provisions garden'
)

# The repo's other Python-using gates probe /usr/bin/python3 first because a mise
# or pyenv interpreter earlier on PATH usually lacks the distro modules.
wiring_python=''
for candidate in /usr/bin/python3 python3; do
  command -v "$candidate" >/dev/null 2>&1 || continue
  if "$candidate" -c 'import yaml' >/dev/null 2>&1; then
    wiring_python=$candidate
    break
  fi
done
[[ -n $wiring_python ]] ||
  fail 'no python3 with PyYAML found; install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)'

checker="$scratch/check_wiring.py"
cat <<'PYTHON' > "$checker"
"""Report CI wiring gaps in the tree at argv[1].

Remaining arguments are `<script-name>=<reason>` exception declarations.
"""
import pathlib
import re
import sys

import yaml

CI_SCRIPT = re.compile(r"\.ci/([A-Za-z0-9._-]+\.sh)")


def strings(node):
    """Every string anywhere in a parsed workflow.

    A `.ci` invocation is usually a step's `run`, but it can also arrive through
    `with:`, an env value, or a composite input. Walking every string keeps a
    legitimately-wired script from being reported as orphaned.
    """
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for value in node.values():
            yield from strings(value)
    elif isinstance(node, list):
        for value in node:
            yield from strings(value)


def main():
    root = pathlib.Path(sys.argv[1])
    exceptions = {}
    for raw in sys.argv[2:]:
        name, _, reason = raw.partition("=")
        exceptions[name] = reason

    ci_dir = root / ".ci"
    workflow_dir = root / ".github" / "workflows"
    failures = []

    invoked = set()
    for workflow in sorted(workflow_dir.glob("*.yml")):
        document = yaml.safe_load(workflow.read_text(encoding="utf-8"))
        for text in strings(document):
            invoked.update(CI_SCRIPT.findall(text))

    # A helper invoked only by its caller is wired through that caller. Comment
    # lines are dropped first: a mention in prose is not an invocation, and
    # counting one would let a script satisfy this gate by being talked about --
    # including in this file's own comments.
    for script in sorted(ci_dir.rglob("*.sh")):
        code = "\n".join(
            line
            for line in script.read_text(encoding="utf-8").splitlines()
            if not line.lstrip().startswith("#")
        )
        for name in CI_SCRIPT.findall(code):
            if name != script.name:
                invoked.add(name)

    gates = sorted(
        path.name
        for path in ci_dir.glob("*.sh")
        if path.is_file()
        and path.stat().st_mode & 0o111
        and (path.name.startswith("test-") or path.name.startswith("check-"))
    )
    for name in gates:
        if name in invoked or name in exceptions:
            continue
        failures.append(
            f"{name} is invoked by no workflow and no other .ci script; "
            f"wire it into a job or declare it an exception"
        )

    for name in sorted(exceptions):
        if not (ci_dir / name).exists():
            failures.append(
                f"exception names .ci/{name}, which does not exist; "
                f"drop the exception or fix the name"
            )

    ci_yml = workflow_dir / "ci.yml"
    if not ci_yml.exists():
        failures.append("no .github/workflows/ci.yml")
    else:
        jobs = (yaml.safe_load(ci_yml.read_text(encoding="utf-8")) or {}).get("jobs") or {}
        delivery = jobs.get("delivery")
        if delivery is None:
            failures.append("ci.yml declares no delivery job to aggregate the others")
        else:
            needs = delivery.get("needs") or []
            if isinstance(needs, str):
                needs = [needs]
            needs = set(needs)
            if not needs:
                failures.append("the delivery job aggregates nothing")
            for job in sorted(jobs):
                if job == "delivery" or job in needs:
                    continue
                failures.append(
                    f"job {job} is absent from delivery's needs, so its failure "
                    f"would not turn the required check red"
                )

    for line in failures:
        print(line, file=sys.stderr)
    return 1 if failures else 0


sys.exit(main())
PYTHON

declared_exceptions=()
for name in "${!exceptions[@]}"; do
  declared_exceptions+=("$name=${exceptions[$name]}")
done

check_tree() {
  "$wiring_python" "$checker" "$@"
}

check_tree "$repo_root" "${declared_exceptions[@]}" || fail 'this repository has CI wiring gaps (listed above)'
pass 'every gate script is wired and every ci.yml job is aggregated'

# The checks above only prove the current tree is clean. These fixtures prove the
# gate would notice if it were not — the same mutant discipline
# .ci/test-chezmoiignore-script-paths.sh uses on its rendered rules.
fixture() {
  local name=$1 tree="$scratch/$1"
  mkdir -p -- "$tree/.ci" "$tree/.github/workflows"
  cat <<'YAML' > "$tree/.github/workflows/ci.yml"
name: CI
jobs:
  alpha:
    steps:
      - run: .ci/test-alpha.sh
  delivery:
    needs: [alpha]
    steps:
      - run: echo aggregate
YAML
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tree/.ci/test-alpha.sh"
  chmod 700 "$tree/.ci/test-alpha.sh"
  printf '%s' "$tree"
}

expect_reject() {
  local tree=$1 label=$2 want=$3 report="$scratch/report"
  shift 3
  if check_tree "$tree" "$@" >"$report" 2>&1; then
    fail "$label was accepted; the gate does not detect it"
  fi
  grep -qF "$want" "$report" ||
    fail "$label was rejected for the wrong reason: $(tr '\n' ';' <"$report")"
  pass "$label"
}

baseline=$(fixture baseline)
check_tree "$baseline" >/dev/null 2>&1 || fail 'the fixture baseline should pass before it is mutated'
pass 'a minimal wired fixture passes'

unaggregated=$(fixture unaggregated)
cat <<'YAML' > "$unaggregated/.github/workflows/ci.yml"
name: CI
jobs:
  alpha:
    steps:
      - run: .ci/test-alpha.sh
  beta:
    steps:
      - run: .ci/test-alpha.sh
  delivery:
    needs: [alpha]
    steps:
      - run: echo aggregate
YAML
expect_reject "$unaggregated" 'a job missing from delivery needs fails' 'job beta is absent'

orphan=$(fixture orphan)
printf '#!/usr/bin/env bash\nexit 0\n' > "$orphan/.ci/test-orphan.sh"
chmod 700 "$orphan/.ci/test-orphan.sh"
expect_reject "$orphan" 'a gate script no workflow invokes fails' 'test-orphan.sh is invoked by no workflow'

stale=$(fixture stale)
expect_reject "$stale" 'an exception naming a missing file fails' \
  'exception names .ci/test-gone.sh' 'test-gone.sh=it moved away'

# The transitive rule is what keeps .ci/check-skip-declarations.sh — invoked only
# by .ci/test-skip-declaration-gates.sh — from reading as an orphan.
transitive=$(fixture transitive)
printf '#!/usr/bin/env bash\nexec .ci/check-helper.sh\n' > "$transitive/.ci/test-alpha.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$transitive/.ci/check-helper.sh"
chmod 700 "$transitive/.ci/test-alpha.sh" "$transitive/.ci/check-helper.sh"
check_tree "$transitive" >/dev/null 2>&1 ||
  fail 'a gate invoked only by another .ci script should count as wired'
pass 'a gate reached through its caller counts as wired'

# The other direction: a declared exception does suppress the orphan report.
excepted=$(fixture excepted)
printf '#!/usr/bin/env bash\nexit 0\n' > "$excepted/.ci/test-orphan.sh"
chmod 700 "$excepted/.ci/test-orphan.sh"
check_tree "$excepted" 'test-orphan.sh=deliberately not run in CI' >/dev/null 2>&1 ||
  fail 'a declared exception for an existing file should pass'
pass 'a declared exception for an existing file passes'

printf 'test-ci-wiring: all tests passed\n'
