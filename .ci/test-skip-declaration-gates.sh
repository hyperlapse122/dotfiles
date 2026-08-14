#!/usr/bin/env bash
set -euo pipefail

# Focused gate for U8: proves .ci/check-skip-declarations.sh actually enforces the
# rendered skip-declaration contract, then runs it against the real production
# tree.
#
# WHY SYNTHETIC FIXTURES. The checker's whole value is that it FAILS on a broken
# rendered surface. Running it only against the production tree proves the clean
# case and nothing else: a checker that silently stopped enforcing would look
# identical. Every case below therefore builds a scratch source tree from the
# PRODUCTION partials (skip.sh.tmpl, fingerprint.tmpl, capabilities.tmpl) plus a
# small synthetic script set shaped like the real adjacent control flow —
# terminal forms in subshell wrappers, a step return, a case-arm hard error, a
# shared guard fanned out across consumers and one always-run lifecycle — and
# then breaks exactly one thing.
#
# The fixture matrix is generated with its digests recomputed from its own
# canonical predicate/continuation strings, so a fixture case can never pass by
# carrying a stale digest.
#
# Cases are run with `--fixture`, which suppresses only the frozen production
# totals (121 owners / 141 instances / 117 + 24); every structural check still
# runs. The last case runs the checker with no flags against the repository.

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
checker=$repo_root/.ci/check-skip-declarations.sh
prog=test-skip-declaration-gates

fail() {
  printf '%s: %s\n' "$prog" "$*" >&2
  exit 1
}

ok() { printf '%s: ok - %s\n' "$prog" "$*"; }

[[ -x $checker ]] || fail "missing $checker"
for surface in .chezmoitemplates/skip.sh.tmpl .chezmoitemplates/fingerprint.tmpl \
  .chezmoitemplates/capabilities.tmpl .ci/skip-declaration-site-matrix.yaml; do
  [[ -e $repo_root/$surface ]] || fail "missing source surface $surface"
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/$prog.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

# --------------------------------------------------------------------------- #
# 1. Build the clean fixture tree
# --------------------------------------------------------------------------- #
clean=$scratch/clean
mkdir -p "$clean/.chezmoiscripts/fixture" "$clean/.ci"
cp -a -- "$repo_root/.chezmoidata" "$clean/.chezmoidata"
cp -a -- "$repo_root/.chezmoitemplates" "$clean/.chezmoitemplates"

# A synthetic SHARED producer: one owner, three consumer instances, exactly the
# shape U6's guards have — the consumer's name is the `script`, the partial's own
# site is the `owner`.
cat >"$clean/.chezmoitemplates/fx-guard.sh.tmpl" <<'TMPL'
{{- $name := .name -}}
if [[ "${FX_GUARD_ELIGIBLE:-0}" != 1 ]]; then
{{ includeTemplate "skip.sh.tmpl" (dict "ctx" .ctx "owner" "fx-guard/ineligible-host" "form" "skip_here" "script" $name "site" "ineligible-host" "direction" "harmless" "reason" "the fixture guard host is ineligible") | trim | indent 2 }}
fi
TMPL

# The phase-local script: one declaration of every accepted shape, plus one
# matrix-named hard error.
cat >"$clean/.chezmoiscripts/fixture/run_onchange_after_fx-main.sh.tmpl" <<'TMPL'
{{- $probe := includeTemplate "capabilities.tmpl" (dict "ctx" . "probe" "mise-present") -}}
#!/usr/bin/env bash
# Fixture consumer: every declaration shape the rendered guard must accept.
{{- includeTemplate "fingerprint.tmpl" (dict "sourceDir" .chezmoi.sourceDir "values" (list (dict "name" "mise-present" "value" $probe))) }}
set -euo pipefail

if [[ ! -d /nonexistent-fx-host-shape ]]; then
{{ includeTemplate "skip.sh.tmpl" (dict "ctx" . "form" "skip_here" "script" "fx-main" "site" "host-shape-absent" "direction" "harmless" "reason" "the fixture host shape is absent") | trim | indent 2 }}
fi

if ! command -v fx-tool >/dev/null 2>&1; then
{{ includeTemplate "skip.sh.tmpl" (dict "ctx" . "form" "skip_here" "script" "fx-main" "site" "tool-absent" "direction" "transient-blocking" "probe" "mise-present" "reason" "the fixture tool is not installed") | trim | indent 2 }}
fi

fx_step() {
  if [[ ! -f /nonexistent-fx-input ]]; then
{{ includeTemplate "skip.sh.tmpl" (dict "ctx" . "form" "skip_step" "script" "fx-main" "site" "step-input-absent" "direction" "transient-blocking" "probe" "mise-present" "reason" "the fixture step input is absent") | trim | indent 4 }}
  fi
  if [[ -f /nonexistent-fx-stamp ]]; then
    (
{{ includeTemplate "skip.sh.tmpl" (dict "ctx" . "form" "done_here" "script" "fx-main" "site" "step-already-done" "reason" "the fixture step is already done") | trim | indent 6 }}
    )
    return 0
  fi
  case "${FX_MODE:-none}" in
    none)
      (
{{ includeTemplate "skip.sh.tmpl" (dict "ctx" . "form" "not_applicable" "script" "fx-main" "site" "mode-none" "reason" "no fixture mode is declared") | trim | indent 8 }}
      )
      ;;
    broken)
      printf '%s\n' 'fx-main: the fixture parser failed; repair the input, then re-apply.' >&2
      exit 1
      ;;
  esac
  printf 'fx-main: step complete\n'
}
fx_step
exit 0
TMPL

for consumer in a b; do
  cat >"$clean/.chezmoiscripts/fixture/run_onchange_after_fx-consumer-$consumer.sh.tmpl" <<TMPL
#!/usr/bin/env bash
{{ includeTemplate "fx-guard.sh.tmpl" (dict "ctx" . "name" "fx-consumer-$consumer") -}}
printf 'fx-consumer-$consumer: configured\n'
exit 0
TMPL
done

# An always-run lifecycle consuming the same shared guard: its instance must be
# reported as lifecycle-excluded, never rendered and never missing.
cat >"$clean/.chezmoiscripts/fixture/run_after_fx-always.sh.tmpl" <<'TMPL'
#!/usr/bin/env bash
{{ includeTemplate "fx-guard.sh.tmpl" (dict "ctx" . "name" "fx-always") -}}
printf 'fx-always: reconciled\n'
exit 0
TMPL

# The fixture matrix, digests recomputed from its own canonical strings.
python3 - "$clean/.ci/skip-declaration-site-matrix.yaml" <<'PY'
import hashlib
import sys

FX = '.chezmoiscripts/fixture'


def digest(value):
    return 'sha256:' + hashlib.sha256(value.encode()).hexdigest()


owners = [
    dict(owner='fx-guard/ineligible-host', scope='guard-partials',
         template='.chezmoitemplates/fx-guard.sh.tmpl', anchor_line=2,
         anchor='if [[ "${FX_GUARD_ELIGIBLE:-0}" != 1 ]]; then',
         predicate='[[ "${FX_GUARD_ELIGIBLE:-0}" != 1 ]]',
         continuation='terminate-script-exit-0', render_profile='any-host',
         form='skip_here', direction='harmless',
         instances=[f'{FX}/run_onchange_after_fx-consumer-a.sh.tmpl#fx-guard/ineligible-host',
                    f'{FX}/run_onchange_after_fx-consumer-b.sh.tmpl#fx-guard/ineligible-host',
                    f'{FX}/run_after_fx-always.sh.tmpl#fx-guard/ineligible-host']),
    dict(owner='fx-main/host-shape-absent', scope='fixture',
         template=f'{FX}/run_onchange_after_fx-main.sh.tmpl', anchor_line=7,
         anchor='if [[ ! -d /nonexistent-fx-host-shape ]]; then',
         predicate='[[ ! -d /nonexistent-fx-host-shape ]]',
         continuation='terminate-script-exit-0', render_profile='any-host',
         form='skip_here', direction='harmless',
         instances=[f'{FX}/run_onchange_after_fx-main.sh.tmpl#fx-main/host-shape-absent']),
    dict(owner='fx-main/tool-absent', scope='fixture',
         template=f'{FX}/run_onchange_after_fx-main.sh.tmpl', anchor_line=11,
         anchor='if ! command -v fx-tool >/dev/null 2>&1; then',
         predicate='! command -v fx-tool >/dev/null 2>&1',
         continuation='terminate-script-exit-0', render_profile='any-host',
         form='skip_here', direction='transient-blocking', probe='mise-present',
         fingerprint_placement='new-header-block',
         instances=[f'{FX}/run_onchange_after_fx-main.sh.tmpl#fx-main/tool-absent']),
    dict(owner='fx-main/step-input-absent', scope='fixture',
         template=f'{FX}/run_onchange_after_fx-main.sh.tmpl', anchor_line=16,
         anchor='  if [[ ! -f /nonexistent-fx-input ]]; then',
         predicate='[[ ! -f /nonexistent-fx-input ]]',
         continuation='abandon-step-return-0', render_profile='any-host',
         form='skip_step', direction='transient-blocking', probe='mise-present',
         fingerprint_placement='new-header-block',
         instances=[f'{FX}/run_onchange_after_fx-main.sh.tmpl#fx-main/step-input-absent']),
    dict(owner='fx-main/step-already-done', scope='fixture',
         template=f'{FX}/run_onchange_after_fx-main.sh.tmpl', anchor_line=19,
         anchor='  if [[ -f /nonexistent-fx-stamp ]]; then',
         predicate='[[ -f /nonexistent-fx-stamp ]]',
         continuation='abandon-step-return-0', render_profile='any-host',
         form='done_here',
         instances=[f'{FX}/run_onchange_after_fx-main.sh.tmpl#fx-main/step-already-done']),
    dict(owner='fx-main/mode-none', scope='fixture',
         template=f'{FX}/run_onchange_after_fx-main.sh.tmpl', anchor_line=26,
         anchor='    none)', predicate='none)',
         continuation='abandon-step-inline-notice', render_profile='any-host',
         form='not_applicable',
         instances=[f'{FX}/run_onchange_after_fx-main.sh.tmpl#fx-main/mode-none']),
]

hard_errors = [
    dict(owner='fx-main/parser-failed', scope='fixture',
         template=f'{FX}/run_onchange_after_fx-main.sh.tmpl', anchor_line=31,
         anchor='    broken)', predicate='broken)', cause='fixture-parser-failure',
         current_outcome='exit-0-skip', required_outcome='nonzero-exit-with-diagnostic'),
]

instances = sum(len(row['instances']) for row in owners)
phase_local = sum(1 for row in owners if len(row['instances']) == 1)

out = ['# Synthetic fixture matrix for .ci/test-skip-declaration-gates.sh.',
       'schema: skip-declaration-site-matrix-v1',
       "frozen_from: 'fixture'",
       "runtime_registry: '.chezmoidata/.capability-registry.tsv'",
       'runtime_input: false',
       '',
       'totals:',
       f'  classified_owners: {len(owners)}',
       f'  hard_error_owners: {len(hard_errors)}',
       f'  rendered_instances: {instances}',
       f'  phase_local_instances: {phase_local}',
       f'  shared_guard_instances: {instances - phase_local}',
       '',
       'shared_guard_fanout:',
       '  fx-guard: 3',
       '',
       'owners:']


def emit(rows, section=None):
    if section:
        out.extend(['', f'{section}:'])
    for row in rows:
        first = True
        for key, value in row.items():
            lead = '  - ' if first else '    '
            first = False
            if key == 'instances':
                out.append(f'{lead}{key}:')
                for inst in value:
                    out.append(f"      - '{inst}'")
                continue
            if isinstance(value, int):
                out.append(f'{lead}{key}: {value}')
                continue
            out.append(f"{lead}{key}: '{value}'")


for row in owners:
    row['predicate_digest'] = digest(row['predicate'])
    row['continuation_digest'] = digest(row['continuation'])
    ordered = {}
    for key in ('owner', 'scope', 'template', 'anchor_line', 'anchor', 'predicate',
                'predicate_digest', 'continuation', 'continuation_digest', 'render_profile',
                'form', 'direction', 'probe', 'fingerprint_placement', 'instances'):
        if key in row:
            ordered[key] = row[key]
    row.clear()
    row.update(ordered)
for row in hard_errors:
    row['predicate_digest'] = digest(row['predicate'])
    ordered = {}
    for key in ('owner', 'scope', 'template', 'anchor_line', 'anchor', 'predicate',
                'predicate_digest', 'cause', 'current_outcome', 'required_outcome'):
        ordered[key] = row[key]
    row.clear()
    row.update(ordered)

emit(owners)
emit(hard_errors, 'hard_errors')
open(sys.argv[1], 'w').write('\n'.join(out) + '\n')
PY

# --------------------------------------------------------------------------- #
# 2. Case harness
# --------------------------------------------------------------------------- #
cases=0

variant() { # label -> prints a fresh mutable copy of the clean tree
  local label=$1
  local dir=$scratch/$label
  rm -rf -- "$dir"
  cp -a -- "$clean" "$dir"
  printf '%s\n' "$dir"
}

expect_pass() { # root label needles...
  local root=$1 label=$2 out
  local rc=0
  shift 2
  out=$("$checker" --fixture "$root" 2>&1) || rc=$?
  if ((rc != 0)); then
    printf '%s\n' "$out" >&2
    fail "$label: expected a clean check, got exit $rc"
  fi
  local needle
  for needle in "$@"; do
    grep -qF -- "$needle" <<<"$out" || {
      printf '%s\n' "$out" >&2
      fail "$label: clean check did not report: $needle"
    }
  done
  cases=$((cases + 1))
  ok "$label"
}

expect_finding() { # root label needle
  local root=$1 label=$2 needle=$3 out
  local rc=0
  out=$("$checker" --fixture "$root" 2>&1) || rc=$?
  if ((rc != 1)); then
    printf '%s\n' "$out" >&2
    fail "$label: expected exit 1 (findings), got exit $rc"
  fi
  grep -qF -- "$needle" <<<"$out" || {
    printf '%s\n' "$out" >&2
    fail "$label: no finding matched: $needle"
  }
  cases=$((cases + 1))
  ok "$label"
}

expect_enforcement_error() { # root label needle
  local root=$1 label=$2 needle=$3 out
  local rc=0
  out=$("$checker" --fixture "$root" 2>&1) || rc=$?
  if ((rc != 2)); then
    printf '%s\n' "$out" >&2
    fail "$label: expected exit 2 (enforcement error), got exit $rc"
  fi
  grep -qF -- "$needle" <<<"$out" || {
    printf '%s\n' "$out" >&2
    fail "$label: no enforcement error matched: $needle"
  }
  cases=$((cases + 1))
  ok "$label"
}

main=.chezmoiscripts/fixture/run_onchange_after_fx-main.sh.tmpl
partial=.chezmoitemplates/skip.sh.tmpl
matrix=.ci/skip-declaration-site-matrix.yaml

# --- 3. The clean tree ----------------------------------------------------- #
# Also the done_here / not_applicable completion case, the matrix-named hard
# error case, and the U4-style always-run exclusion case: all three are part of
# what a clean tree must accept.
expect_pass "$clean" 'clean fixture tree reconciles' \
  '6 matrix owners, 1 hard errors, 8 declared instances' \
  '7 instances rendered + 1 lifecycle-excluded + 0 missing = 8' \
  'lifecycle-excluded .chezmoiscripts/fixture/run_after_fx-always.sh.tmpl#fx-guard/ineligible-host' \
  '1 of 1 matrix-named hard errors verified nonzero and unclaimed' \
  'rendered declaration surface matches the matrix'

# --- 3b. chezmoi reachable only through PATH -------------------------------- #
# The checker renders under `env -i` with a sanitized PATH, and `env` resolves
# the program name against THAT PATH — so a chezmoi that only the caller's PATH
# can reach must be pinned to its resolved location before the render. CI unpacks
# the locked build into $RUNNER_TEMP/bin and appends it to $GITHUB_PATH, never
# into /usr/bin, so a bare command name renders nothing there. The stand-in is
# named so it cannot be resolved from the sanitized PATH by accident.
pathbin=$scratch/pathbin
mkdir -p "$pathbin"
ln -s -- "$(command -v "${CHEZMOI:-chezmoi}")" "$pathbin/chezmoi-only-on-path"
rc=0
out=$(PATH="$pathbin:$PATH" CHEZMOI=chezmoi-only-on-path \
  "$checker" --fixture "$clean" 2>&1) || rc=$?
if ((rc != 0)); then
  printf '%s\n' "$out" >&2
  fail "a chezmoi reachable only through PATH still renders: expected a clean check, got exit $rc"
fi
grep -qF -- 'rendered declaration surface matches the matrix' <<<"$out" || {
  printf '%s\n' "$out" >&2
  fail 'a chezmoi reachable only through PATH still renders: no reconciliation reported'
}
cases=$((cases + 1))
ok 'a chezmoi reachable only through PATH still renders'

# --- 4. Bare conditional success exit -------------------------------------- #
dir=$(variant bare-exit)
python3 - "$dir/$main" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = 'fx_step\nexit 0\n'
assert text.count(needle) == 1, 'fixture tail anchor changed'
open(path, 'w').write(text.replace(
    needle,
    'if [[ ! -f /nonexistent-fx-late-input ]]; then\n  exit 0\nfi\nfx_step\nexit 0\n'))
PY
expect_finding "$dir" 'a bare conditional success exit fails' \
  'undeclared conditional success exit (exit 0)'

dir=$(variant bare-step-return)
python3 - "$dir/$main" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = "  printf 'fx-main: step complete\\n'\n"
assert text.count(needle) == 1, 'fixture step tail anchor changed'
open(path, 'w').write(text.replace(
    needle, '  if [[ ! -f /nonexistent-fx-late-step ]]; then\n    return 0\n  fi\n' + needle))
PY
expect_finding "$dir" 'a bare conditional step return fails' \
  'undeclared conditional success exit (return 0)'

# --- 5. Missing declaration ------------------------------------------------ #
dir=$(variant missing-sentinel)
python3 - "$dir/$main" <<'PY'
import re
import sys
path = sys.argv[1]
lines = open(path).read().split('\n')
kept = [line for line in lines if 'site" "host-shape-absent"' not in line]
assert len(kept) == len(lines) - 1
open(path, 'w').write('\n'.join(kept).replace(
    'if [[ ! -d /nonexistent-fx-host-shape ]]; then\nfi\n', ''))
PY
expect_finding "$dir" 'a missing declaration fails' \
  '#fx-main/host-shape-absent: declared instance never rendered'

dir=$(variant missing-shared-instance)
rm -- "$dir/.chezmoiscripts/fixture/run_onchange_after_fx-consumer-b.sh.tmpl"
expect_finding "$dir" 'a missing shared-guard consumer instance fails' \
  'run_onchange_after_fx-consumer-b.sh.tmpl#fx-guard/ineligible-host: declared instance never rendered'

# --- 6. Duplicate declaration ---------------------------------------------- #
dir=$(variant duplicate-sentinel)
python3 - "$dir/$main" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
call = [line for line in text.split('\n') if 'site" "host-shape-absent"' in line][0]
open(path, 'w').write(text.replace(call, call + '\n' + call))
PY
expect_finding "$dir" 'a duplicated declaration fails' \
  'fx-main/host-shape-absent: duplicate declaration'

# --- 7. Malformed sentinel ------------------------------------------------- #
dir=$(variant malformed-sentinel)
python3 - "$dir/$partial" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = 'probe=%s fingerprint=%s'
assert text.count(needle) == 1, 'sentinel format anchor changed'
open(path, 'w').write(text.replace(needle, 'fingerprint=%s', 1).replace(
    '(or $probe "none") $fingerprint', '$fingerprint', 1))
PY
expect_finding "$dir" 'a malformed sentinel fails' 'malformed sentinel'

# --- 8. Relocated declaration ---------------------------------------------- #
dir=$(variant relocated-sentinel)
python3 - "$dir/$main" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
call = [line for line in text.split('\n') if 'site" "host-shape-absent"' in line][0]
open(path, 'w').write(text.replace(
    call, "  printf 'fx-main: about to skip\\n'\n" + call))
PY
expect_finding "$dir" 'a declaration that no longer opens its branch fails' \
  'fx-main/host-shape-absent: sentinel does not open the branch'

dir=$(variant relocated-subshell)
python3 - "$dir/$main" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
call = [line for line in text.split('\n') if 'site" "step-already-done"' in line][0]
open(path, 'w').write(text.replace(
    call, "      printf 'fx-main: about to stamp\\n'\n" + call))
PY
expect_finding "$dir" 'a declaration that no longer opens its subshell wrapper fails' \
  'fx-main/step-already-done: sentinel does not open its subshell wrapper'

# --- 9. Matrix mismatch ---------------------------------------------------- #
dir=$(variant matrix-form-mismatch)
python3 - "$dir/$matrix" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
text = text.replace("""  - owner: 'fx-main/host-shape-absent'""", """  - owner: 'fx-main/host-shape-absent'""")
open(path, 'w').write(text.replace("form: 'skip_here'\n    direction: 'harmless'\n    instances:\n      - '.chezmoiscripts/fixture/run_onchange_after_fx-main.sh.tmpl#fx-main/host-shape-absent'",
                                   "form: 'skip_step'\n    direction: 'harmless'\n    instances:\n      - '.chezmoiscripts/fixture/run_onchange_after_fx-main.sh.tmpl#fx-main/host-shape-absent'", 1))
PY
expect_finding "$dir" 'a form that disagrees with the matrix fails' \
  'form skip_here does not match matrix form skip_step'

dir=$(variant matrix-instance-mismatch)
python3 - "$dir/$matrix" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = "      - '.chezmoiscripts/fixture/run_onchange_after_fx-main.sh.tmpl#fx-main/tool-absent'"
new = "      - '.chezmoiscripts/fixture/run_onchange_after_fx-consumer-a.sh.tmpl#fx-main/tool-absent'"
assert text.count(old) == 1
open(path, 'w').write(text.replace(old, new))
PY
expect_finding "$dir" 'a declaration rendered outside its declared instance fails' \
  'is not a declared instance of this owner'

dir=$(variant matrix-placement-mismatch)
python3 - "$dir/$matrix" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
assert text.count("fingerprint_placement: 'new-header-block'") == 2
open(path, 'w').write(text.replace("fingerprint_placement: 'new-header-block'",
                                   "fingerprint_placement: 'existing-header-block'", 1))
PY
expect_finding "$dir" 'a fingerprint block in the wrong placement fails' \
  'matrix declares existing-header-block'

# --- 10. Changed predicate ------------------------------------------------- #
dir=$(variant changed-predicate)
python3 - "$dir/$main" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = 'if [[ ! -d /nonexistent-fx-host-shape ]]; then'
assert text.count(old) == 1
open(path, 'w').write(text.replace(old, 'if [[ ! -d /nonexistent-fx-other-shape ]]; then'))
PY
expect_finding "$dir" 'a changed precondition fails its matrix digest check' \
  'does not match the matrix predicate'

# --- 11. Changed continuation --------------------------------------------- #
dir=$(variant changed-continuation)
python3 - "$dir/$main" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = '    )\n    return 0\n  fi\n'
assert text.count(old) == 1, 'subshell wrapper anchor changed'
open(path, 'w').write(text.replace(old, '    )\n  fi\n'))
PY
expect_finding "$dir" 'dropping the bounded return after a subshell wrapper fails' \
  'rendered continuation abandon-step-inline-notice does not match matrix continuation abandon-step-return-0'

dir=$(variant unwrapped-terminal-form)
python3 - "$dir/$main" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
lines = text.split('\n')
idx = next(i for i, line in enumerate(lines) if 'site" "step-already-done"' in line)
assert lines[idx - 1].strip() == '(' and lines[idx + 1].strip() == ')'
call = lines[idx].replace('| trim | indent 6', '| trim | indent 4')
open(path, 'w').write('\n'.join(lines[:idx - 1] + [call] + lines[idx + 2:]))
PY
expect_finding "$dir" 'a terminal form that escapes its subshell wrapper fails' \
  'rendered continuation terminate-script-exit-0 does not match matrix continuation abandon-step-return-0'

# --- 12. Invalid declaration ---------------------------------------------- #
dir=$(variant invalid-direction-sentinel)
python3 - "$dir/$partial" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = '(or $direction "none")'
assert text.count(needle) == 1, 'sentinel direction anchor changed'
open(path, 'w').write(text.replace(needle, '"sideways"'))
PY
expect_finding "$dir" 'an invalid rendered direction fails' 'invalid direction'

dir=$(variant invalid-direction-call)
python3 - "$dir/$main" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
open(path, 'w').write(text.replace('"direction" "harmless"', '"direction" "sideways"', 1))
PY
expect_enforcement_error "$dir" 'an invalid declaration aborts the render' \
  'cannot render .chezmoiscripts/fixture/run_onchange_after_fx-main.sh.tmpl'

# --- 13. Blocking declaration without its cached fingerprint -------------- #
dir=$(variant missing-fingerprint)
python3 - "$dir/$main" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().split('\n')
kept = [line for line in lines if 'fingerprint.tmpl' not in line]
assert len(kept) == len(lines) - 1
open(path, 'w').write('\n'.join(kept))
PY
expect_finding "$dir" 'a blocking declaration without its cached fingerprint value fails' \
  'transient-blocking declaration without the cached fingerprint value value:mise-present'

# --- 14. Matrix-named hard error ------------------------------------------ #
dir=$(variant hard-error-becomes-success)
python3 - "$dir/$main" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = "      printf '%s\\n' 'fx-main: the fixture parser failed; repair the input, then re-apply.' >&2\n      exit 1\n"
assert text.count(old) == 1, 'hard error anchor changed'
open(path, 'w').write(text.replace(old, "      printf '%s\\n' 'fx-main: the fixture parser failed; skipping.'\n      exit 0\n"))
PY
expect_finding "$dir" 'a hard error that degrades into a success exit fails' \
  'no longer reaches a nonzero exit'

dir=$(variant hard-error-vanished)
python3 - "$dir/$main" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = """    broken)
      printf '%s\\n' 'fx-main: the fixture parser failed; repair the input, then re-apply.' >&2
      exit 1
      ;;
"""
assert text.count(old) == 1, 'hard error arm anchor changed'
open(path, 'w').write(text.replace(old, ''))
PY
expect_finding "$dir" 'a hard error that disappears from the rendered surface fails' \
  'no rendered branch matches its predicate'

# --- 15. Lifecycle drives the surface ------------------------------------- #
dir=$(variant lifecycle-promoted)
mv -- "$dir/.chezmoiscripts/fixture/run_after_fx-always.sh.tmpl" \
  "$dir/.chezmoiscripts/fixture/run_onchange_after_fx-always.sh.tmpl"
expect_finding "$dir" 'promoting an always-run script into the onchange lifecycle fails' \
  'run_after_fx-always.sh.tmpl#fx-guard/ineligible-host: declared instance never rendered'

# --- 16. Enforcement errors ----------------------------------------------- #
dir=$(variant missing-scan-root)
rm -rf -- "$dir/.chezmoiscripts"
expect_enforcement_error "$dir" 'a missing scan root reports an enforcement error' \
  'missing scan root'

dir=$(variant missing-matrix)
rm -f -- "$dir/$matrix"
expect_enforcement_error "$dir" 'a missing matrix reports an enforcement error' \
  'missing site matrix'

dir=$(variant unparsable-render)
python3 - "$dir/$main" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
open(path, 'w').write(text.replace('fx_step\nexit 0\n', 'fx_step\nfi\nexit 0\n'))
PY
expect_enforcement_error "$dir" 'unparsable rendered shell stops the check' \
  'unparsable rendered shell'

# --- 17. The production tree ---------------------------------------------- #
printf '%s: running the production check (%s)\n' "$prog" "$checker"
production_rc=0
production_out=$("$checker" "$repo_root" 2>&1) || production_rc=$?
printf '%s\n' "$production_out"
if ((production_rc != 0)); then
  fail "the production rendered declaration surface does not reconcile (exit $production_rc)"
fi
cases=$((cases + 1))
ok 'production rendered declaration surface reconciles'

printf '%s: %d cases passed\n' "$prog" "$cases"
