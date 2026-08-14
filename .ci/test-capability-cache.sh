#!/usr/bin/env bash
# Focused gate for U2: the frozen CI-only site matrix, the versioned runtime
# capability registry, and the per-command capability cache the
# read-source-state.pre hook publishes for .chezmoitemplates/capabilities.tmpl.
#
# Everything runtime here goes through REAL `chezmoi` commands against a scratch
# source, destination, HOME and cache. The fixture hook sources the production
# .install-prerequisites.sh through its existing test seam and calls the production
# write_capability_cache, so the code under test is the shipped code; only the
# malformed-record modes bypass it, which is the point of those cases.
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

matrix=".ci/skip-declaration-site-matrix.yaml"
registry=".chezmoidata/.capability-registry.tsv"
identity_helper=".chezmoitemplates/capability-cache-identity.sh"
partial=".chezmoitemplates/capabilities.tmpl"
hook=".install-prerequisites.sh"

fail() {
  printf 'test-capability-cache: %s\n' "$*" >&2
  exit 1
}

for surface in "$matrix" "$registry" "$identity_helper" "$partial" "$hook" \
  ".chezmoitemplates/fingerprint.tmpl" ".chezmoitemplates/skip.sh.tmpl"; do
  [[ -f "$repo_root/$surface" ]] || fail "missing source surface $surface"
done

# --- 1. Matrix and registry accounting -------------------------------------
# The matrix is parsed by a fixed-shape reader rather than a YAML library: no
# PyYAML on the CI runners, and the oracle only needs the subset it is written in.
python3 - "$repo_root" "$matrix" "$registry" <<'PY' || fail 'matrix/registry accounting failed'
import hashlib
import re
import sys
from pathlib import Path

root, matrix_rel, registry_rel = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
problems = []


def unquote(value):
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1].replace("''", "'")
    return value


def parse(path):
    top, section, current = {}, None, None
    pending_list = None
    for raw in path.read_text().splitlines():
        if not raw.strip() or raw.lstrip().startswith('#'):
            continue
        if re.match(r'^ {6}- ', raw):
            if pending_list is None:
                problems.append(f'list item outside a list: {raw!r}')
                continue
            pending_list.append(unquote(raw.strip()[2:]))
            continue
        if raw.startswith('  - '):
            current = {}
            top.setdefault(section, []).append(current)
            raw = '    ' + raw[4:]
        if raw.startswith('    '):
            key, _, value = raw.strip().partition(':')
            value = value.strip()
            if current is None:
                problems.append(f'row field outside a row: {raw!r}')
                continue
            if value == '':
                pending_list = current[key] = []
            else:
                pending_list = None
                current[key] = int(value) if re.fullmatch(r'-?\d+', value) else unquote(value)
            continue
        if raw.startswith('  '):
            key, _, value = raw.strip().partition(':')
            top.setdefault(section, {})[key] = int(value.strip()) if re.fullmatch(r'-?\d+', value.strip()) else unquote(value.strip())
            continue
        key, _, value = raw.partition(':')
        section, current, pending_list = key.strip(), None, None
        if value.strip():
            top[section] = unquote(value.strip())
    return top


matrix = parse(root / matrix_rel)

if matrix.get('schema') != 'skip-declaration-site-matrix-v1':
    problems.append(f'unexpected matrix schema {matrix.get("schema")!r}')
if matrix.get('runtime_input') != 'false':
    problems.append('the matrix must declare runtime_input: false')

owners = matrix.get('owners', [])
hard_errors = matrix.get('hard_errors', [])
totals = matrix.get('totals', {})

# The frozen R5 boundary. These numbers are the contract U6/U7/U8 execute against,
# so they are asserted literally rather than derived from the rows. The fatal subset
# is ELEVEN: the plan's GNOME parser and Figma/Kimi build causes plus
# config-kde-calendar/akonadi-query-failed, a live SQL read failure on an eligible
# host that the plan's session-settled R5 decision authorizes as a hard error.
frozen = {
    'classified_owners': 124,
    'hard_error_owners': 11,
    'rendered_instances': 144,
    'phase_local_instances': 120,
    'shared_guard_instances': 24,
}
for key, expected in frozen.items():
    if totals.get(key) != expected:
        problems.append(f'totals.{key} is {totals.get(key)!r}, expected {expected}')
if len(owners) != frozen['classified_owners']:
    problems.append(f'{len(owners)} owner rows, expected {frozen["classified_owners"]}')
if len(hard_errors) != frozen['hard_error_owners']:
    problems.append(f'{len(hard_errors)} hard-error rows, expected {frozen["hard_error_owners"]}')

# The plan Appendix's own splits, recorded verbatim in the matrix so a re-audit can
# never quietly replace them. Where the audit differs, the matrix must carry a
# divergence entry for exactly that bucket — no silent drift, and no stale entry
# once a bucket is brought back into line.
plan_contract = matrix.get('plan_contract', {})
expected_plan = {'harmless': 41, 'transient_blocking': 47, 'done_here': 10,
                 'not_applicable': 22, 'hard_error_owners': 11}
for key, expected in expected_plan.items():
    if plan_contract.get(key) != expected:
        problems.append(f'plan_contract.{key} is {plan_contract.get(key)!r}, but the plan Appendix fixes {expected}')
if 'feedback-sweep-plan.md' not in str(plan_contract.get('source', '')):
    problems.append('plan_contract must cite the feedback-sweep plan Appendix')

audited_forms = matrix.get('audited_forms', {})
audited_directions = matrix.get('audited_directions', {})
audited_scopes = matrix.get('audited_scopes', {})
plan_scopes = matrix.get('plan_contract_scopes', {})
divergence = {row.get('bucket'): row for row in matrix.get('divergence', [])}
for row in matrix.get('divergence', []):
    if not str(row.get('reason', '')).strip():
        problems.append(f'divergence for {row.get("bucket")!r} carries no reason')

FORMS = {'skip_here', 'skip_step', 'done_here', 'not_applicable'}
DIRECTIONS = {'harmless', 'transient-blocking', 'transient-tolerable'}
REQUIRED = ['owner', 'scope', 'template', 'anchor_line', 'anchor', 'predicate',
            'predicate_digest', 'continuation', 'continuation_digest',
            'render_profile', 'form', 'instances']
CONTINUATIONS = {'terminate-script-exit-0', 'abandon-step-return-0',
                 'abandon-step-inline-notice', 'terminate-script-render-branch'}
SHARED = {'gnome-guard': 8, 'kde-guard': 9, 'headless-guard': 3, 'sudo-skip-guard': 4}

# `anchor`/`anchor_line` are the RAW pre-conversion snapshot (evidence), while
# `predicate` is the canonical condition the rendered declaration branches on — that
# is what U8 recomputes from the rendered tree and compares. So a predicate must be a
# bare condition: statement syntax means someone pasted the anchor into it.
STATEMENT_SYNTAX = re.compile(r';\s*then\b|\|\|\s*return\s+0|\|\|\s*\{|\bexit\s+0\b|\breturn\s+0\b|;;|\\$')
# The other direction: anchors must keep their raw shape. These owners' anchors
# carry control flow that their canonical predicate deliberately drops, so if an
# anchor ever loses it, the evidence was overwritten with the canonical form.
RAW_ANCHOR_EVIDENCE = {
    'install-fedora/mok-generate-no-efi': '|| return 0',
    'install-fedora/mok-generate-secureboot-disabled': '|| return 0',
    'install-fedora/mok-keypair-present': 'return 0 ;;',
    'install-fedora/nvidia-repo-policy-no-nvidia': '|| return 0',
    'install-fedora/timedatectl-absent': '|| return 0',
    'install-fedora/enable-unit-absent': '|| return 0',
    'config-gnome-fonts/fc-match-absent': '|| return 0',
    'luks-tpm2/tool-not-deployed': 'exit 0;',
    'update-omp-plugins/no-eligible-plugins': 'exit 0; fi',
    'update-omp-plugins/no-plugins-or-removals': 'exit 0; fi',
    'config-gnome-1password-shortcut/gsettings-absent': 'command -v gsettings',
    'config-kde-wallpaper-breeze/wallpaper-tool-absent': 'command -v plasma-apply-wallpaperimage',
}

seen_owners, seen_instances, blocking_probes = set(), set(), set()
shared_seen, phase_local_instances = {}, 0

for row in owners:
    owner = row.get('owner', '<missing>')
    missing = [field for field in REQUIRED if field not in row]
    if missing:
        problems.append(f'{owner}: missing fields {missing}')
        continue
    unknown = set(row) - set(REQUIRED) - {'direction', 'probe', 'fingerprint_placement'}
    if unknown:
        problems.append(f'{owner}: unknown fields {sorted(unknown)}')
    if owner in seen_owners:
        problems.append(f'duplicate owner identity {owner}')
    seen_owners.add(owner)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*', owner):
        problems.append(f'{owner}: owner must be <script>/<site>, both safe filename components')
    if not (root / row['template']).is_file():
        problems.append(f'{owner}: template {row["template"]} does not exist')
    if row['form'] not in FORMS:
        problems.append(f'{owner}: unknown form {row["form"]!r}')
    if row['continuation'] not in CONTINUATIONS:
        problems.append(f'{owner}: unknown continuation {row["continuation"]!r}')
    if not row['anchor'].strip() or not isinstance(row['anchor_line'], int) or row['anchor_line'] < 1:
        problems.append(f'{owner}: incomplete pre-conversion anchor')
    for field in ('predicate', 'continuation'):
        want = 'sha256:' + hashlib.sha256(row[field].encode()).hexdigest()
        if row[f'{field}_digest'] != want:
            problems.append(f'{owner}: {field}_digest does not match its normalized {field}')
    if STATEMENT_SYNTAX.search(row['predicate']) or not row['predicate'].strip():
        problems.append(f'{owner}: predicate {row["predicate"]!r} is not a canonical condition — '
                        'the rendered declaration branches on a bare condition, and the raw '
                        'source line belongs in `anchor`')
    if owner in RAW_ANCHOR_EVIDENCE and RAW_ANCHOR_EVIDENCE[owner] not in row['anchor']:
        problems.append(f'{owner}: anchor lost its raw pre-conversion shape '
                        f'(expected to contain {RAW_ANCHOR_EVIDENCE[owner]!r}, got {row["anchor"]!r})')
    if row['form'] in {'skip_here', 'skip_step'}:
        if row.get('direction') not in DIRECTIONS:
            problems.append(f'{owner}: skip form needs a valid direction, got {row.get("direction")!r}')
        if row.get('direction') == 'transient-tolerable':
            problems.append(f'{owner}: transient-tolerable has no site in this repository')
    elif 'direction' in row:
        problems.append(f'{owner}: form {row["form"]} takes no direction')
    if row.get('direction') == 'transient-blocking':
        if not row.get('probe'):
            problems.append(f'{owner}: transient-blocking without a registry probe')
        else:
            blocking_probes.add(row['probe'])
        if row.get('fingerprint_placement') not in {'existing-header-block', 'new-header-block'}:
            problems.append(f'{owner}: transient-blocking without a fingerprint placement')
    elif row.get('probe'):
        problems.append(f'{owner}: only transient-blocking rows may name a probe')

    script = owner.split('/', 1)[0]
    instances = row['instances']
    if script in SHARED:
        shared_seen[script] = shared_seen.get(script, 0) + len(instances)
        if len(instances) != SHARED[script]:
            problems.append(f'{owner}: shared guard declares {len(instances)} instances, expected {SHARED[script]}')
    else:
        phase_local_instances += len(instances)
        if len(instances) != 1:
            problems.append(f'{owner}: a phase-local owner declares exactly one rendered instance')
    for instance in instances:
        if instance in seen_instances:
            problems.append(f'duplicate owner/instance identity {instance}')
        seen_instances.add(instance)
        consumer, sep, tail = instance.partition('#')
        if not sep or tail != owner:
            problems.append(f'{owner}: instance {instance} must name its owner after #')
        if not (root / consumer).is_file():
            problems.append(f'{owner}: instance consumer {consumer} does not exist')

if shared_seen != SHARED:
    problems.append(f'shared guard fan-out is {shared_seen}, expected {SHARED}')
if phase_local_instances != frozen['phase_local_instances']:
    problems.append(f'{phase_local_instances} phase-local instances, expected {frozen["phase_local_instances"]}')
if len(seen_instances) != frozen['rendered_instances']:
    problems.append(f'{len(seen_instances)} rendered instances, expected {frozen["rendered_instances"]}')

form_counts, direction_counts, scope_counts = {}, {}, {}
for row in owners:
    form_counts[row.get('form')] = form_counts.get(row.get('form'), 0) + 1
    scope_counts[row.get('scope')] = scope_counts.get(row.get('scope'), 0) + 1
    if row.get('direction'):
        direction_counts[row['direction']] = direction_counts.get(row['direction'], 0) + 1
for label, declared, counted in (('audited_forms', audited_forms, form_counts),
                                 ('audited_scopes', audited_scopes, scope_counts)):
    if {key: value for key, value in declared.items() if value} != {k: v for k, v in counted.items() if v}:
        problems.append(f'{label} says {declared}, the rows say {counted}')
if {key: value for key, value in audited_directions.items() if value} != direction_counts:
    problems.append(f'audited_directions says {audited_directions}, the rows say {direction_counts}')

# Reconciliation, both ways: a bucket that differs from the plan needs a divergence
# entry carrying the same two numbers, and a bucket that matches must NOT carry one.
audited_buckets = {
    'harmless': direction_counts.get('harmless', 0),
    'transient_blocking': direction_counts.get('transient-blocking', 0),
    'done_here': form_counts.get('done_here', 0),
    'not_applicable': form_counts.get('not_applicable', 0),
    'hard_error_owners': len(hard_errors),
}
scope_combined = dict(scope_counts)
scope_combined['00-tools+10-auth'] = scope_counts.get('00-tools', 0) + scope_counts.get('10-auth', 0)
for bucket, expected in list(expected_plan.items()) + [(f'scope:{name}', count) for name, count in plan_scopes.items()]:
    audited = audited_buckets.get(bucket)
    if audited is None:
        audited = scope_combined.get(bucket.removeprefix('scope:'), 0)
    entry = divergence.get(bucket)
    if audited == expected:
        if entry is not None:
            problems.append(f'{bucket} matches the plan at {expected} but still carries a divergence entry')
        continue
    if entry is None:
        problems.append(f'{bucket} is {audited}, the plan fixes {expected}, and the matrix declares no divergence')
    elif (entry.get('plan'), entry.get('audited')) != (expected, audited):
        problems.append(f'{bucket} divergence records {entry.get("plan")}/{entry.get("audited")}, '
                        f'actual {expected}/{audited}')
for bucket in divergence:
    if bucket not in expected_plan and bucket.removeprefix('scope:') not in plan_scopes:
        problems.append(f'divergence names unknown bucket {bucket!r}')

# The settled fatal boundary: four GNOME gsettings/dconf parser cases, six
# Figma/Kimi dependency-install, build and missing-dist causes, and the KDE Akonadi
# SQL read that fails after mariadb and its socket both check out. Nothing else, and
# never a skip declaration.
expected_hard = {
    ('config-gnome-1password-shortcut/gsettings-read-failed', 'gsettings-get-failure'),
    ('config-gnome-1password-shortcut/keybindings-parse-error', 'dconf-parser-failure'),
    ('config-gnome-remove-ibus-source/gsettings-read-failed', 'gsettings-get-failure'),
    ('config-gnome-remove-ibus-source/sources-parse-error', 'dconf-parser-failure'),
    ('build-figma-auth/dependency-install-failed', 'dependency-install-failure'),
    ('build-figma-auth/build-failed', 'build-failure'),
    ('build-figma-auth/missing-dist', 'missing-dist-artifact'),
    ('build-kimi-reconcile/dependency-install-failed', 'dependency-install-failure'),
    ('build-kimi-reconcile/build-failed', 'build-failure'),
    ('build-kimi-reconcile/missing-dist', 'missing-dist-artifact'),
    ('config-kde-calendar/akonadi-query-failed', 'akonadi-query-failure'),
}
seen_hard = set()
for row in hard_errors:
    owner = row.get('owner', '<missing>')
    for field in ('owner', 'scope', 'template', 'anchor_line', 'anchor', 'cause',
                  'current_outcome', 'required_outcome'):
        if field not in row:
            problems.append(f'hard error {owner}: missing {field}')
    if row.get('required_outcome') != 'nonzero-exit-with-diagnostic':
        problems.append(f'hard error {owner}: must require a nonzero exit')
    if 'form' in row or 'direction' in row:
        problems.append(f'hard error {owner}: a hard error is never a declared skip')
    if not (root / row.get('template', '')).is_file():
        problems.append(f'hard error {owner}: template {row.get("template")} does not exist')
    if STATEMENT_SYNTAX.search(row.get('predicate', '')) or not row.get('predicate', '').strip():
        problems.append(f'hard error {owner}: predicate {row.get("predicate")!r} is not a canonical condition')
    if row.get('predicate_digest') != 'sha256:' + hashlib.sha256(row.get('predicate', '').encode()).hexdigest():
        problems.append(f'hard error {owner}: predicate_digest does not match its predicate')
    seen_hard.add((owner, row.get('cause')))
    if owner in seen_owners:
        problems.append(f'hard error {owner} also appears as a classified owner')
if seen_hard != expected_hard:
    problems.append(f'hard-error set drifted: unexpected {sorted(seen_hard - expected_hard)}, '
                    f'missing {sorted(expected_hard - seen_hard)}')

# --- registry ---
registry_text = (root / registry_rel).read_text()
registry_lines = registry_text.split('\n')
if registry_lines[0] != 'capability-registry-v2':
    problems.append('registry must start with capability-registry-v2')
if registry_lines[-1] != '':
    problems.append('registry must end with a newline')
keys, kinds, platforms, previous = [], {}, {}, ''
for number, line in enumerate(registry_lines[1:-1], start=2):
    fields = line.split('\t')
    if len(fields) != 6:
        problems.append(f'registry line {number} has {len(fields)} columns, expected 6')
        continue
    key, kind, side_effect, platform, available, unavailable = fields
    if not re.fullmatch(r'[a-z0-9][a-z0-9.-]*', key):
        problems.append(f'registry line {number}: invalid key {key!r}')
    if key <= previous:
        problems.append(f'registry line {number}: {key} is unsorted or duplicated')
    previous = key
    if platform not in {'any', 'linux'}:
        problems.append(f'registry line {number}: {key} has unknown platform applicability {platform!r}')
    if (available, unavailable) != ('available', 'unavailable'):
        problems.append(f'registry line {number}: {key} must declare the fixed available/unavailable tokens')
    if side_effect not in {'none', 'read-only-subprocess', 'sudo-credential-probe'}:
        problems.append(f'registry line {number}: {key} has unknown side-effect class {side_effect!r}')
    if not re.fullmatch(r'[a-z-]+', kind):
        problems.append(f'registry line {number}: {key} has invalid probe kind {kind!r}')
    keys.append(key)
    kinds[key] = kind
    platforms[key] = platform

if len(keys) != 35:
    problems.append(f'registry has {len(keys)} probes, expected 35')
if {key for key, platform in platforms.items() if platform == 'any'} != {
        'mise-present', 'gh-present', 'glab-present', 'tokscale-present'}:
    problems.append('only mise-present, gh-present, glab-present, and tokscale-present may be any-platform probes')
if platforms.get('podman-socket-unit-present') != 'linux':
    problems.append('podman-socket-unit-present must remain Linux-scoped')
if kinds.get('podman-socket-unit-present') != 'user-manager-unit':
    problems.append('podman-socket-unit-present must use the reviewed user-manager-unit kind')
if set(keys) != blocking_probes:
    problems.append(f'registry/matrix probe mismatch: registry-only {sorted(set(keys) - blocking_probes)}, '
                    f'matrix-only {sorted(blocking_probes - set(keys))}')
if len(registry_text.encode()) == 0:
    problems.append('registry is empty')

if problems:
    for problem in problems:
        print(f'  - {problem}')
    sys.exit(1)
print(f'matrix: {len(owners)} owners, {len(hard_errors)} hard errors, '
      f'{len(seen_instances)} instances, {len(keys)} registry probes')
PY

# Every kind the registry declares must select reviewed code in the hook, and the
# reader must contain no probe of its own.
while IFS=$'\t' read -r _ kind _ _ _ _; do
  [[ -n "$kind" ]] || continue
  grep -qE "^    ${kind}\)" "$repo_root/$hook" \
    || fail "registry probe kind $kind has no reviewed resolver branch in $hook"
done < <(tail -n +2 "$repo_root/$registry")

# The reader may spawn exactly ONE child, and only to derive this command's
# identity. Checking the `output` calls themselves (rather than any mention of a
# probe) keeps this precise: the partial's header legitimately DISCUSSES sudo -nN
# and gsettings while executing neither.
mapfile -t output_calls < <(grep -nE '\{\{-? *[^*].*output "' "$repo_root/$partial")
[[ ${#output_calls[@]} -eq 1 ]] \
  || fail "$partial makes ${#output_calls[@]} subprocess calls; only the identity child is allowed"
for forbidden in sudo gsettings pgrep systemctl 'command -v'; do
  if [[ "${output_calls[0]}" == *"$forbidden"* ]]; then
    fail "$partial still probes from a template ($forbidden); probes belong to the hook"
  fi
done
[[ "${output_calls[0]}" == *'CAPABILITY_CACHE_OWNER_PID'* ]] \
  || fail "$partial's only subprocess must derive the capability-cache identity"
grep -qE 'CAPABILITY_CACHE_OWNER_PID=.*\$PPID' "$repo_root/$partial" \
  || fail "$partial must pass its direct chezmoi parent's PPID to the identity helper"
grep -qE 'CAPABILITY_CACHE_OWNER_PID=.*\$PPID' "$repo_root/$hook" \
  || fail "$hook must pass its direct chezmoi parent's PPID to the identity helper"
grep -qE '^write_capability_cache "\$\{CHEZMOI_SOURCE_DIR:-\}"$' "$repo_root/$hook" \
  || fail "$hook must explicitly pass CHEZMOI_SOURCE_DIR to write_capability_cache"
if grep -vE '^[[:space:]]*#' "$repo_root/$identity_helper" | grep -qE '\$\$|\$PPID|\$BASHPID|\$0'; then
  fail "$identity_helper must derive no PID of its own; the caller supplies CAPABILITY_CACHE_OWNER_PID"
fi
grep -qE 'timeout [0-9]+ sudo -nN true' "$repo_root/$hook" \
  || fail "$hook must keep the bounded, non-refreshing sudo -nN probe"
grep -qF 'capability_with_deadline systemctl --user show-environment' "$repo_root/$hook" \
  || fail 'user-manager-bus must use the portable bounded resolver'
grep -qF 'capability_with_deadline systemctl --user cat podman.socket' "$repo_root/$hook" \
  || fail 'podman-socket-unit-present must use native bounded systemctl --user cat behavior'
for banned in 'capability' 'sudo-usable' 'session-bus'; do
  if grep -qi -- "$banned" "$repo_root/.chezmoidata/facts.yaml"; then
    fail "capabilities leaked into the fact registry (.chezmoidata/facts.yaml mentions $banned)"
  fi
done

# --- 2. Runtime fixture ----------------------------------------------------
chezmoi_bin=$(type -P chezmoi) || fail 'chezmoi is not on PATH'
source_digest_before=$(sha256sum \
  "$repo_root/$registry" "$repo_root/$identity_helper" "$repo_root/$partial" "$repo_root/$hook")

scratch_parent=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}
mkdir -p -- "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/capability-cache.XXXXXX")
trap 'chmod -R u+rwX -- "$scratch" 2>/dev/null || true; rm -rf -- "$scratch"' EXIT

source_dir="$scratch/source"
unknown_source="$scratch/source-unknown"
destination="$scratch/destination"
fixture_home="$scratch/home"
cache_home="$scratch/cache"
runtime_dir="$scratch/runtime"
stub_bin="$scratch/bin"
tool_bin="$scratch/toolbin"
log="$scratch/probe.log"
capability_dir="$cache_home/chezmoi/capabilities"

mkdir -p -- "$source_dir/.chezmoidata" "$source_dir/.chezmoitemplates" \
  "$unknown_source/.chezmoidata" "$unknown_source/.chezmoitemplates" \
  "$destination" "$fixture_home" "$cache_home" "$runtime_dir" "$stub_bin" "$tool_bin"

# A hermetic PATH. The fixture must not inherit whichever probed tools this
# workstation happens to have installed, or "the tool is absent" cases would pass
# or fail by accident: only the stubs below can satisfy a command-present probe.
for tool in sh bash env uname sha256sum shasum cut awk mktemp stat chmod mkdir rm \
  mv ln id timeout grep sed head tail cat sleep touch wc sort tr basename dirname \
  pgrep ps find printf; do
  tool_path=$(type -P "$tool") || continue
  ln -sf -- "$tool_path" "$tool_bin/$tool"
done

# --- why the registry basename is dot-prefixed ------------------------------
# chezmoi discovers .chezmoidata/ recursively and refuses a file whose extension it
# has no parser for, which would abort EVERY chezmoi command in this repository. A
# dot-prefixed entry is skipped instead — and the registry must not become template
# data anyway. This proves both halves against the installed chezmoi, so the day the
# behaviour changes, this case says so instead of the path staying odd forever.
format_probe="$scratch/format-probe"
mkdir -p -- "$format_probe/.chezmoidata"
: >"$scratch/format-probe.toml"
printf 'rendered' >"$scratch/format-probe.tmpl"
cp -- "$repo_root/$registry" "$format_probe/.chezmoidata/capability-registry.tsv"
render_format_probe() {
  env HOME="$fixture_home" "$chezmoi_bin" --config "$scratch/format-probe.toml" \
    --source "$format_probe" --destination "$destination" --no-tty execute-template \
    <"$scratch/format-probe.tmpl" >"$scratch/format-probe.out" 2>"$scratch/format-probe.err"
}
if render_format_probe; then
  fail 'a visible .chezmoidata/capability-registry.tsv no longer breaks chezmoi; the dot prefix can be dropped'
fi
grep -qF 'unknown format' "$scratch/format-probe.err" \
  || fail "a visible registry failed for an unexpected reason: $(cat "$scratch/format-probe.err")"
grep -qF 'capability-registry.tsv' "$scratch/format-probe.err" \
  || fail 'the unknown-format failure did not name the registry file'
mv -- "$format_probe/.chezmoidata/capability-registry.tsv" \
  "$format_probe/.chezmoidata/.capability-registry.tsv"
render_format_probe || fail "chezmoi rejected the dot-prefixed registry: $(cat "$scratch/format-probe.err")"
[[ "$(cat "$scratch/format-probe.out")" == rendered ]] \
  || fail 'the dot-prefixed registry did not leave rendering intact'
[[ ! -e "$repo_root/.chezmoidata/capability-registry.tsv" ]] \
  || fail 'a visible registry exists in the repository; it would break every chezmoi command'

for shared in "$registry:.chezmoidata/.capability-registry.tsv" \
  "$identity_helper:.chezmoitemplates/capability-cache-identity.sh" \
  "$partial:.chezmoitemplates/capabilities.tmpl" \
  ".chezmoitemplates/fingerprint.tmpl:.chezmoitemplates/fingerprint.tmpl"; do
  cp -- "$repo_root/${shared%%:*}" "$source_dir/${shared##*:}"
  cp -- "$repo_root/${shared%%:*}" "$unknown_source/${shared##*:}"
done

cat >"$source_dir/dot_probe.tmpl" <<'TEMPLATE'
{{- $zsh := includeTemplate "capabilities.tmpl" (dict "ctx" . "probe" "zsh-present") -}}
{{- $sudo := includeTemplate "capabilities.tmpl" (dict "ctx" . "probe" "sudo-usable") -}}
{{- $bus := includeTemplate "capabilities.tmpl" (dict "ctx" . "probe" "session-bus-present") -}}
{{- $plasma := includeTemplate "capabilities.tmpl" (dict "ctx" . "probe" "plasmashell-running") -}}
zsh={{ $zsh }} sudo={{ $sudo }} bus={{ $bus }} plasma={{ $plasma }}
{{ includeTemplate "fingerprint.tmpl" (dict "sourceDir" .chezmoi.sourceDir "values" (list
     (dict "name" "zsh-present" "value" $zsh)
     (dict "name" "sudo-usable" "value" $sudo)
     (dict "name" "session-bus-present" "value" $bus)
     (dict "name" "plasmashell-running" "value" $plasma))) }}
TEMPLATE

# A second consumer in the same command: two more sudo reads, so a per-call probe
# would show up as three sudo invocations instead of one.
cat >"$source_dir/dot_probe_second.tmpl" <<'TEMPLATE'
{{- $sudo := includeTemplate "capabilities.tmpl" (dict "ctx" . "probe" "sudo-usable") -}}
{{- $again := includeTemplate "capabilities.tmpl" (dict "ctx" . "probe" "sudo-usable") -}}
sudo={{ $sudo }} again={{ $again }}
TEMPLATE

cat >"$source_dir/dot_darwin.tmpl" <<'TEMPLATE'
{{- $mise := includeTemplate "capabilities.tmpl" (dict "ctx" . "probe" "mise-present") -}}
{{- $gh := includeTemplate "capabilities.tmpl" (dict "ctx" . "probe" "gh-present") -}}
{{- $glab := includeTemplate "capabilities.tmpl" (dict "ctx" . "probe" "glab-present") -}}
{{- $tokscale := includeTemplate "capabilities.tmpl" (dict "ctx" . "probe" "tokscale-present") -}}
mise={{ $mise }} gh={{ $gh }} glab={{ $glab }} tokscale={{ $tokscale }}
{{ includeTemplate "fingerprint.tmpl" (dict "sourceDir" .chezmoi.sourceDir "values" (list
     (dict "name" "mise-present" "value" $mise)
     (dict "name" "gh-present" "value" $gh)
     (dict "name" "glab-present" "value" $glab)
     (dict "name" "tokscale-present" "value" $tokscale))) }}
TEMPLATE

registry_v1_source="$scratch/source-registry-v1"
registry_malformed_source="$scratch/source-registry-malformed"
cp -a -- "$source_dir" "$registry_v1_source"
cp -a -- "$source_dir" "$registry_malformed_source"
python3 - \
  "$registry_v1_source/.chezmoidata/.capability-registry.tsv" \
  "$registry_malformed_source/.chezmoidata/.capability-registry.tsv" <<'PY'
from pathlib import Path
import sys

v1_path, malformed_path = map(Path, sys.argv[1:])
v1_lines = v1_path.read_text().splitlines()
v1_lines[0] = 'capability-registry-v1'
for index, line in enumerate(v1_lines[1:], start=1):
    fields = line.split('\t')
    del fields[3]
    v1_lines[index] = '\t'.join(fields)
v1_path.write_text('\n'.join(v1_lines) + '\n')

malformed_lines = malformed_path.read_text().splitlines()
fields = malformed_lines[1].split('\t')
fields[3] = 'darwin'
malformed_lines[1] = '\t'.join(fields)
malformed_path.write_text('\n'.join(malformed_lines) + '\n')
PY

cat >"$unknown_source/dot_unknown.tmpl" <<'TEMPLATE'
{{ includeTemplate "capabilities.tmpl" (dict "ctx" . "probe" "definitely-not-a-probe") }}
TEMPLATE

cat >"$stub_bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$FIXTURE_LOG"
[[ -z "${FIXTURE_PROBE_DELAY:-}" ]] || sleep "$FIXTURE_PROBE_DELAY"
[[ "${FIXTURE_SUDO:-unavailable}" == available ]]
STUB
cat >"$stub_bin/zsh" <<'STUB'
#!/usr/bin/env bash
printf 'zsh %s\n' "$*" >>"$FIXTURE_LOG"
exit 0
STUB
cat >"$stub_bin/pgrep" <<'STUB'
#!/usr/bin/env bash
printf 'pgrep %s\n' "$*" >>"$FIXTURE_LOG"
[[ "${FIXTURE_PLASMASHELL:-unavailable}" == available ]]
STUB
cat >"$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$FIXTURE_LOG"
case "$*" in
  '--user show-environment')
    [[ "${FIXTURE_SYSTEMCTL_DELAY_TARGET:-}" != manager ]] ||
      sleep "${FIXTURE_SYSTEMCTL_DELAY_SECS:-10}"
    exit 0
    ;;
  '--user cat podman.socket')
    [[ "${FIXTURE_PODMAN_UNIT:-available}" == available ]] || exit 1
    [[ "${FIXTURE_SYSTEMCTL_DELAY_TARGET:-}" != unit ]] ||
      sleep "${FIXTURE_SYSTEMCTL_DELAY_SECS:-10}"
    exit 0
    ;;
  *) exit 1 ;;
esac
STUB
for tool in mise gh glab tokscale; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$stub_bin/$tool"
  chmod +x "$stub_bin/$tool"
done
chmod +x "$stub_bin/sudo" "$stub_bin/zsh" "$stub_bin/pgrep" "$stub_bin/systemctl"

# The fixture hook: production code for the `real` mode, deliberate malformed
# records for the reader-contract modes. `$PPID` here is chezmoi itself.
cat >"$scratch/fixture-hook.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
_INSTALL_PREREQUISITES_TEST_SOURCE=1
# shellcheck disable=SC1090
source "$FIXTURE_REPO_ROOT/.install-prerequisites.sh"
unset _INSTALL_PREREQUISITES_TEST_SOURCE

printf 'hook-owner-pid %s\n' "$PPID" >>"$FIXTURE_LOG"
mode=${FIXTURE_CACHE_MODE:-real}

if [[ "$mode" == real ]]; then
  write_capability_cache "$FIXTURE_SOURCE"
  printf 'records-after-publish %s %s\n' "$PPID" \
    "$(find "${XDG_CACHE_HOME:-$HOME/.cache}/chezmoi/capabilities" -name '*.tsv' -printf '%f ')" \
    >>"$FIXTURE_LOG"
  # Stay alive after publishing so a sibling command's hook runs while this
  # invocation's record is genuinely live.
  [[ -z "${FIXTURE_HOOK_HOLD:-}" ]] || sleep "$FIXTURE_HOOK_HOLD"
  exit 0
fi

CAPABILITY_CACHE_IDENTITY_MAIN=0
# shellcheck disable=SC1090
source "$FIXTURE_SOURCE/.chezmoitemplates/capability-cache-identity.sh"
unset CAPABILITY_CACHE_IDENTITY_MAIN
read_capability_registry "$FIXTURE_SOURCE/.chezmoidata/.capability-registry.tsv"
IFS=$'\t' read -r _ owner_pid marker identity \
  < <(CAPABILITY_CACHE_OWNER_PID="$PPID" capability_cache_identity_emit)

dir="${XDG_CACHE_HOME:-$HOME/.cache}/chezmoi/capabilities"
mkdir -p "$dir"
chmod 700 "$dir"
record="$dir/$identity.tsv"
rm -rf -- "$record"

write_record() {
  local schema=$1 record_identity=$2 digest=$3 keys=$4
  {
    printf '%s\t%s\t%s\t%s\t%s\n' "$schema" "$record_identity" "$owner_pid" "$marker" "$digest"
    if [[ "$keys" == all ]]; then
      for key in "${CAPABILITY_KEYS[@]}"; do printf '%s\tavailable\n' "$key"; done
    else
      printf '%s\tavailable\n' "${CAPABILITY_KEYS[0]}"
    fi
  } >"$record"
  chmod 600 "$record"
}

case "$mode" in
  corrupt) printf 'not-a-capability-record\n' >"$record"; chmod 600 "$record" ;;
  incomplete) write_record "$CAPABILITY_CACHE_SCHEMA" "$identity" "$CAPABILITY_REGISTRY_DIGEST" first ;;
  prior-schema) write_record 'capability-cache-v0' "$identity" "$CAPABILITY_REGISTRY_DIGEST" all ;;
  prior-registry) write_record "$CAPABILITY_CACHE_SCHEMA" "$identity" "$(printf '0%.0s' {1..64})" all ;;
  foreign-identity) write_record "$CAPABILITY_CACHE_SCHEMA" "$(printf 'f%.0s' {1..64})" "$CAPABILITY_REGISTRY_DIGEST" all ;;
  group-readable) write_record "$CAPABILITY_CACHE_SCHEMA" "$identity" "$CAPABILITY_REGISTRY_DIGEST" all; chmod 640 "$record" ;;
  not-regular) mkdir -p "$record" ;;
  stale-then-fault)
    # A VALID record for this very identity, claiming a capability that is no
    # longer true, followed by a directory the hook can neither write nor clean.
    write_record "$CAPABILITY_CACHE_SCHEMA" "$identity" "$CAPABILITY_REGISTRY_DIGEST" all
    printf 'seeded-stale-record %s\n' "$record" >>"$FIXTURE_LOG"
    chmod 500 "$dir"
    write_capability_cache "$FIXTURE_SOURCE"
    ;;
  *) printf 'fixture-hook: unknown mode %s\n' "$mode" >&2; exit 2 ;;
esac
HOOK
chmod +x "$scratch/fixture-hook.sh"

printf '[hooks.read-source-state.pre]\n    script = "%s/fixture-hook.sh"\n' "$scratch" >"$scratch/hooked.toml"
: >"$scratch/no-hook.toml"

run_chezmoi() {
  local config=$1 source=$2 sudo_state=$3 bus=$4 mode=$5
  local fixture_path="$stub_bin:$tool_bin"
  shift 5
  [[ -z "${FIXTURE_PLATFORM_BIN:-}" ]] || fixture_path="$FIXTURE_PLATFORM_BIN:$fixture_path"
  local -a environment=(
    HOME="$fixture_home"
    XDG_CACHE_HOME="$cache_home"
    XDG_RUNTIME_DIR="$runtime_dir"
    PATH="$fixture_path"
    FIXTURE_REPO_ROOT="$repo_root"
    FIXTURE_SOURCE="$source"
    FIXTURE_LOG="${FIXTURE_LOG_FILE:-$log}"
    FIXTURE_SUDO="$sudo_state"
    FIXTURE_CACHE_MODE="$mode"
    FIXTURE_SYSTEMCTL_DELAY_TARGET="${FIXTURE_SYSTEMCTL_DELAY_TARGET:-}"
    FIXTURE_SYSTEMCTL_DELAY_SECS="${FIXTURE_SYSTEMCTL_DELAY_SECS:-}"
    FIXTURE_PLASMASHELL="${FIXTURE_PLASMASHELL:-}"
    FIXTURE_PODMAN_UNIT="${FIXTURE_PODMAN_UNIT:-}"
    CAPABILITY_PROBE_DEADLINE_SECS="${CAPABILITY_PROBE_DEADLINE_SECS:-}"
    CAPABILITY_PROBE_TERM_GRACE_SECS="${CAPABILITY_PROBE_TERM_GRACE_SECS:-}"
  )
  [[ "$bus" == present ]] && environment+=(DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus")
  [[ -z "${FIXTURE_PROBE_DELAY:-}" ]] || environment+=(FIXTURE_PROBE_DELAY="$FIXTURE_PROBE_DELAY")
  [[ -z "${FIXTURE_HOOK_HOLD:-}" ]] || environment+=(FIXTURE_HOOK_HOLD="$FIXTURE_HOOK_HOLD")
  env -u DBUS_SESSION_BUS_ADDRESS "${environment[@]}" \
    "$chezmoi_bin" --config "$config" --source "$source" --destination "$destination" \
      --persistent-state "$scratch/state.boltdb" --cache "$scratch/chezmoi-cache" \
      --no-tty "$@"
}

apply_fixture() {
  local sudo_state=$1 bus=$2 mode=${3:-real}
  : >"$log"
  run_chezmoi "$scratch/hooked.toml" "$source_dir" "$sudo_state" "$bus" "$mode" \
    --force apply >"$scratch/stdout" 2>"$scratch/stderr"
}

rendered() { cat "$destination/.probe"; }
probe_line() { head -n 1 "$destination/.probe"; }
count_log() { grep -c "^$1" "$log" || true; }
reset_cache() {
  chmod -R u+rwX -- "$capability_dir" 2>/dev/null || true
  rm -rf -- "$capability_dir" "$destination"
  mkdir -p -- "$destination"
}

# --- source-root fallback resolution ----------------------------------------
# The production call explicitly passes CHEZMOI_SOURCE_DIR when it is available,
# avoiding ambiguity with the function's positional source-root argument. The
# function's CWD-independent environment and BASH_SOURCE fallbacks are both
# independently exercised here.
resolve_root_case() {
  local label=$1 expected_registry=$2
  shift 2
  reset_cache
  env -u DBUS_SESSION_BUS_ADDRESS HOME="$fixture_home" XDG_CACHE_HOME="$cache_home" \
    XDG_RUNTIME_DIR="$runtime_dir" PATH="$stub_bin:$tool_bin" FIXTURE_LOG="$log" \
    FIXTURE_SUDO=unavailable "$@" \
    bash -c '_INSTALL_PREREQUISITES_TEST_SOURCE=1
      source "$1"
      unset _INSTALL_PREREQUISITES_TEST_SOURCE
      write_capability_cache' bash "$repo_root/$hook" \
    >"$scratch/resolve.out" 2>"$scratch/resolve.err" \
    || fail "$label: write_capability_cache failed: $(cat "$scratch/resolve.err")"
  local written=("$capability_dir"/*.tsv)
  [[ ${#written[@]} -eq 1 ]] || fail "$label: expected one record, found ${#written[@]}"
  [[ "$(head -n 1 "${written[0]}" | cut -f5)" == "$(sha256sum <"$expected_registry" | cut -d' ' -f1)" ]] \
    || fail "$label: the record digest does not come from $expected_registry"
}
resolve_root_case 'CHEZMOI_SOURCE_DIR' "$source_dir/.chezmoidata/.capability-registry.tsv" \
  CHEZMOI_SOURCE_DIR="$source_dir"
resolve_root_case 'BASH_SOURCE fallback' "$repo_root/$registry"

assert_registry_rejected() {
  local source=$1 expected=$2
  reset_cache
  if run_chezmoi "$scratch/hooked.toml" "$source" unavailable absent real \
    --force apply >"$scratch/stdout" 2>"$scratch/stderr"; then
    fail "malformed registry $source rendered successfully"
  fi
  grep -qF "$expected" "$scratch/stderr" \
    || fail "malformed registry $source did not report $expected: $(cat "$scratch/stderr")"
}
assert_registry_rejected "$registry_v1_source" 'must start with capability-registry-v2'
assert_registry_rejected "$registry_malformed_source" 'declares platform applicability'

# --- Darwin resolves only reviewed any-platform command probes ----------------
darwin_bin="$scratch/darwin-bin"
mkdir -p -- "$darwin_bin"
printf '#!/usr/bin/env bash\nprintf %%s Darwin\n' >"$darwin_bin/uname"
chmod +x "$darwin_bin/uname"
apply_darwin_fixture() {
  FIXTURE_PLATFORM_BIN="$darwin_bin" apply_fixture unavailable absent
}

reset_cache
apply_darwin_fixture || fail "a Darwin host failed to publish a record: $(cat "$scratch/stderr")"
[[ "$(head -n 1 "$destination/.darwin")" == 'mise=available gh=available glab=available tokscale=available' ]] \
  || fail "Darwin did not publish the active any-platform tools: $(head -n 1 "$destination/.darwin")"
darwin_first=$(cat "$destination/.darwin")
darwin_records=("$capability_dir"/*.tsv)
[[ ${#darwin_records[@]} -eq 1 ]] || fail 'Darwin published no single record'
darwin_record=${darwin_records[0]}
while IFS=$'\t' read -r key _ _ platform _ _; do
  [[ -n "$key" ]] || continue
  if [[ "$platform" == any ]]; then
    grep -qx "$key"$'\tavailable' "$darwin_record" \
      || fail "Darwin did not publish available for applicable $key"
  else
    grep -qx "$key"$'\tunavailable' "$darwin_record" \
      || fail "Darwin did not publish unavailable for Linux-only $key"
  fi
done < <(tail -n +2 "$source_dir/.chezmoidata/.capability-registry.tsv")
for resolver in 'sudo ' 'systemctl ' 'pgrep '; do
  [[ "$(count_log "$resolver")" -eq 0 ]] \
    || fail "Darwin launched the Linux-only $resolver resolver"
done

mv -- "$stub_bin/tokscale" "$scratch/tokscale.hidden"
reset_cache
apply_darwin_fixture || fail "Darwin without tokscale failed: $(cat "$scratch/stderr")"
[[ "$(head -n 1 "$destination/.darwin")" == 'mise=available gh=available glab=available tokscale=unavailable' ]] \
  || fail 'an absent Darwin tool did not publish unavailable'
[[ "$(cat "$destination/.darwin")" != "$darwin_first" ]] \
  || fail 'a Darwin capability token flip did not change the rendered fingerprint'
mv -- "$scratch/tokscale.hidden" "$stub_bin/tokscale"
reset_cache
apply_darwin_fixture || fail "Darwin after restoring tokscale failed: $(cat "$scratch/stderr")"
[[ "$(cat "$destination/.darwin")" == "$darwin_first" ]] \
  || fail 'restoring a Darwin tool did not restore its available fingerprint'

# --- once per command, and nothing probes from a template ---
reset_cache
apply_fixture available present
[[ "$(probe_line)" == 'zsh=available sudo=available bus=available plasma=unavailable' ]] \
  || fail "hook-backed render did not publish live tokens: $(probe_line)"
[[ "$(count_log 'sudo ')" -eq 1 ]] \
  || fail "sudo-usable resolved $(count_log 'sudo ') times in one command; it must resolve exactly once"
grep -qx 'sudo -nN true' "$log" \
  || fail 'the sudo probe must stay the bounded, non-refreshing `sudo -nN true` check'
[[ "$(cat "$destination/.probe_second")" == 'sudo=available again=available' ]] \
  || fail 'a second consumer in the same command read a different token'

records=("$capability_dir"/*.tsv)
[[ ${#records[@]} -eq 1 ]] || fail "expected exactly one record, found ${#records[@]}"
record=${records[0]}
[[ "$(stat -c '%a' "$capability_dir")" == 700 ]] || fail 'the capability cache directory must be 0700'
[[ "$(stat -c '%a' "$record")" == 600 ]] || fail 'a capability record must be 0600'
[[ -f "$record" && ! -L "$record" ]] || fail 'a capability record must be a regular file'
hook_owner_pid=$(awk '$1 == "hook-owner-pid" { print $2 }' "$log" | tail -n 1)
record_owner_pid=$(head -n 1 "$record" | cut -f3)
[[ "$hook_owner_pid" == "$record_owner_pid" ]] \
  || fail "writer identity ($hook_owner_pid) and record owner ($record_owner_pid) disagree"
[[ "$(basename -- "$record")" == "$(head -n 1 "$record" | cut -f2).tsv" ]] \
  || fail 'the record name must be the identity it stores'
[[ "$(head -n 1 "$record" | cut -f5)" == "$(sha256sum <"$source_dir/.chezmoidata/.capability-registry.tsv" | cut -d' ' -f1)" ]] \
  || fail 'the record digest is not the digest of the exact registry bytes'
[[ "$(tail -n +2 "$record" | wc -l)" == "$(tail -n +2 "$source_dir/.chezmoidata/.capability-registry.tsv" | wc -l)" ]] \
  || fail 'the record must carry exactly one token per registry key'

[[ "$(awk -F'\t' '$1 == "user-manager-bus-present" { print $2 }' "$record")" == available ]] \
  || fail 'a responsive user manager did not publish available'
[[ "$(awk -F'\t' '$1 == "podman-socket-unit-present" { print $2 }' "$record")" == available ]] \
  || fail 'a responsive podman socket unit did not publish available'
for delayed_probe in manager unit; do
  reset_cache
  started=$SECONDS
  CAPABILITY_PROBE_DEADLINE_SECS=1 CAPABILITY_PROBE_TERM_GRACE_SECS=1 \
    FIXTURE_SYSTEMCTL_DELAY_TARGET="$delayed_probe" apply_fixture unavailable absent \
    || fail "a delayed $delayed_probe probe aborted the command: $(cat "$scratch/stderr")"
  elapsed=$((SECONDS - started))
  ((elapsed <= 4)) \
    || fail "the delayed $delayed_probe probe exceeded its bounded deadline (${elapsed}s)"
  [[ ! -s "$scratch/stderr" ]] \
    || fail "the delayed $delayed_probe probe emitted a diagnostic instead of an unavailable token"
  delayed_records=("$capability_dir"/*.tsv)
  [[ ${#delayed_records[@]} -eq 1 ]] || fail "the delayed $delayed_probe probe published no single record"
  delayed_record=${delayed_records[0]}
  if [[ "$delayed_probe" == manager ]]; then
    delayed_key=user-manager-bus-present
    responsive_key=podman-socket-unit-present
  else
    delayed_key=podman-socket-unit-present
    responsive_key=user-manager-bus-present
  fi
  [[ "$(awk -F'\t' -v key="$delayed_key" '$1 == key { print $2 }' "$delayed_record")" == unavailable ]] \
    || fail "the delayed $delayed_probe probe was not unavailable"
  [[ "$(awk -F'\t' -v key="$responsive_key" '$1 == key { print $2 }' "$delayed_record")" == available ]] \
    || fail "the responsive companion probe did not stay available"
done

# --- repeated reads are stable; a token flip moves the fingerprint ---
reset_cache
apply_fixture available present
stable_first=$(rendered)
apply_fixture available present
if [[ "$(rendered)" != "$stable_first" ]]; then
  fail 'two commands with the same host state rendered different content'
fi
flip_reference=$(rendered)
mv -- "$stub_bin/zsh" "$scratch/zsh.hidden"
reset_cache
apply_fixture available present
[[ "$(probe_line)" == 'zsh=unavailable sudo=available bus=available plasma=unavailable' ]] \
  || fail "a removed tool did not flip its token: $(probe_line)"
[[ "$(rendered)" != "$flip_reference" ]] || fail 'a token flip did not change the rendered fingerprint'
unavailable_reference=$(rendered)
apply_fixture available present
[[ "$(rendered)" == "$unavailable_reference" ]] || fail 'an unchanged unavailable token was not byte-stable'
mv -- "$scratch/zsh.hidden" "$stub_bin/zsh"
reset_cache
apply_fixture available present
plasma_before=$(rendered)
FIXTURE_PLASMASHELL=available apply_fixture available present
[[ "$(probe_line)" == 'zsh=available sudo=available bus=available plasma=available' ]] \
  || fail "a running plasmashell did not publish available: $(probe_line)"
[[ "$(rendered)" != "$plasma_before" ]] \
  || fail 'a plasmashell token flip did not change the rendered fingerprint'
plasma_reference=$(rendered)
FIXTURE_PLASMASHELL=available apply_fixture available present
[[ "$(rendered)" == "$plasma_reference" ]] \
  || fail 'an unchanged plasmashell token was not byte-stable'

reset_cache
apply_fixture unavailable absent
[[ "$(probe_line)" == 'zsh=available sudo=unavailable bus=unavailable plasma=unavailable' ]] \
  || fail "absent session bus / unusable sudo did not resolve unavailable: $(probe_line)"
reset_cache
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$runtime_dir/bus"
apply_fixture unavailable absent
[[ "$(probe_line)" == 'zsh=available sudo=unavailable bus=available plasma=unavailable' ]] \
  || fail "a session-bus socket alone did not resolve available: $(probe_line)"
rm -f -- "$runtime_dir/bus"

# --- identity isolation: two simultaneous commands with identical arguments ----
# A holds its hook open after publishing, so B's hook — same argv, same cache,
# different session state — runs while A's record is genuinely live. B must publish
# its own record, read only its own, and leave A's alone; A must then render its own
# tokens through the record it published before B ever started.
reset_cache
: >"$scratch/log-a"
: >"$scratch/log-b"
(
  FIXTURE_LOG_FILE="$scratch/log-a" FIXTURE_HOOK_HOLD=3 \
    run_chezmoi "$scratch/hooked.toml" "$source_dir" available present real \
      cat "$destination/.probe" >"$scratch/concurrent-a" 2>"$scratch/concurrent-a.err"
) &
first=$!
sleep 1
(
  FIXTURE_LOG_FILE="$scratch/log-b" \
    run_chezmoi "$scratch/hooked.toml" "$source_dir" available absent real \
      cat "$destination/.probe" >"$scratch/concurrent-b" 2>"$scratch/concurrent-b.err"
) &
second=$!
wait "$second" || fail "concurrent command B failed: $(cat "$scratch/concurrent-b.err")"
wait "$first" || fail "concurrent command A failed: $(cat "$scratch/concurrent-a.err")"
grep -q 'bus=available' "$scratch/concurrent-a" \
  || fail "concurrent command A read another invocation's session state: $(cat "$scratch/concurrent-a")"
grep -q 'bus=unavailable' "$scratch/concurrent-b" \
  || fail "concurrent command B read another invocation's session state: $(cat "$scratch/concurrent-b")"
b_view=$(awk '$1 == "records-after-publish" { $1 = ""; $2 = ""; print }' "$scratch/log-b")
[[ $(wc -w <<<"$b_view") -eq 2 ]] \
  || fail "B saw records [$b_view] after publishing; a live sibling's record must survive"
a_identity=$(awk '$1 == "hook-owner-pid" { print $2 }' "$scratch/log-a")
b_identity=$(awk '$1 == "hook-owner-pid" { print $2 }' "$scratch/log-b")
[[ -n "$a_identity" && "$a_identity" != "$b_identity" ]] \
  || fail 'two simultaneous commands resolved the same owner PID'

# --- a different command shape is a different identity ---
reset_cache
apply_fixture available present
apply_record=("$capability_dir"/*.tsv)
FIXTURE_HOOK_HOLD=1 run_chezmoi "$scratch/hooked.toml" "$source_dir" available present real \
  cat "$destination/.probe" >"$scratch/variant" 2>&1 || fail "variant command failed: $(cat "$scratch/variant")"
[[ ! -f "${apply_record[0]}" ]] \
  || fail 'a finished command left its record behind for a later command to read'
grep -q 'zsh=available' "$scratch/variant" \
  || fail "the variant command did not publish and read its own record: $(cat "$scratch/variant")"
variant_records=("$capability_dir"/*.tsv)
[[ ${#variant_records[@]} -eq 1 && "${variant_records[0]}" != "${apply_record[0]}" ]] \
  || fail 'a different command shape reused the previous identity'

# --- a record whose owner is provably gone is pruned; nothing else is ---
reset_cache
apply_fixture available present
dead_record="$capability_dir/$(printf 'a%.0s' {1..64}).tsv"
{
  printf 'capability-cache-v1\t%s\t%s\t%s\t%s\n' "$(printf 'a%.0s' {1..64})" 999999 4242 \
    "$(sha256sum <"$source_dir/.chezmoidata/.capability-registry.tsv" | cut -d' ' -f1)"
  tail -n +2 "$source_dir/.chezmoidata/.capability-registry.tsv" | cut -f1 |
    while IFS= read -r key; do printf '%s\tavailable\n' "$key"; done
} >"$dead_record"
chmod 600 "$dead_record"
apply_fixture available present
[[ ! -e "$dead_record" ]] || fail 'a record whose owning command has ended was not pruned'
[[ $(find "$capability_dir" -name '*.tsv' | wc -l) -ge 1 ]] || fail 'pruning removed the record this command published'

# --- no hook: an isolated render is safely unavailable ---
reset_cache
run_chezmoi "$scratch/no-hook.toml" "$source_dir" available present real \
  --force apply >"$scratch/stdout" 2>"$scratch/stderr" \
  || fail "a hook-bypassing render aborted: $(cat "$scratch/stderr")"
[[ "$(probe_line)" == 'zsh=unavailable sudo=unavailable bus=unavailable plasma=unavailable' ]] \
  || fail "a hook-bypassing render did not fall back to unavailable: $(probe_line)"
[[ ! -d "$capability_dir" ]] || fail 'a reader must never create the cache directory'

# --- every malformed record variant is treated as no record at all ---
for variant in corrupt incomplete prior-schema prior-registry foreign-identity \
  group-readable not-regular; do
  reset_cache
  apply_fixture available present "$variant" \
    || fail "the $variant record aborted the command: $(cat "$scratch/stderr")"
  [[ "$(probe_line)" == 'zsh=unavailable sudo=unavailable bus=unavailable plasma=unavailable' ]] \
    || fail "the $variant record was trusted: $(probe_line)"
done

# --- unknown probe is a hard render failure ---
reset_cache
if run_chezmoi "$scratch/hooked.toml" "$unknown_source" available present real \
  --force apply >"$scratch/stdout" 2>"$scratch/stderr"; then
  fail 'an unknown probe name rendered successfully'
fi
grep -qF 'unknown probe "definitely-not-a-probe"' "$scratch/stderr" \
  || fail 'an unknown probe did not produce the known-probe diagnostic'
grep -qF 'Known probes: akonadi-socket-present' "$scratch/stderr" \
  || fail 'the unknown-probe diagnostic must enumerate the registry keys'

# --- a cache-integrity fault stops the command before a stale token renders ----
# The seeded record claims every capability is available while the truth is that
# `zsh` is gone, so a render from that record is distinguishable from no render at
# all — and the unwritable directory makes replacement AND invalidation impossible.
reset_cache
mv -- "$stub_bin/zsh" "$scratch/zsh.hidden"
apply_fixture available present
[[ "$(probe_line)" == 'zsh=unavailable'* ]] \
  || fail "fixture precondition: the pre-fault render should say zsh=unavailable, got $(probe_line)"
previous_render=$(rendered)
if apply_fixture available present stale-then-fault; then
  fail 'an unwritable capability cache did not fail the command'
fi
grep -qF 'capability cache:' "$scratch/stderr" || fail 'the cache-integrity failure had no diagnostic'
grep -qF 'refusing to render' "$scratch/stderr" \
  || fail 'the cache-integrity failure did not say it refuses to render'
[[ "$(grep -c 'seeded-stale-record' "$log")" -eq 1 ]] \
  || fail 'fixture precondition: the stale record was not seeded'
stale_record=$(awk '$1 == "seeded-stale-record" { print $2 }' "$log")
awk -F'\t' '$1 == "zsh-present" && $2 == "available" { found = 1 } END { exit found ? 0 : 1 }' \
  "$stale_record" \
  || fail 'fixture precondition: the seeded record should claim zsh-present is available'
[[ "$(rendered)" == "$previous_render" ]] \
  || fail 'the aborted command rewrote a target from a record it did not publish'
grep -q 'zsh=unavailable' "$destination/.probe" \
  || fail 'the stale available token reached a rendered target'
mv -- "$scratch/zsh.hidden" "$stub_bin/zsh"

production_script="$scratch/production-podman.sh"
production_target="$scratch/production-target"
production_render_err="$scratch/production-render.err"
mkdir -p -- "$production_target"
env -i HOME="$fixture_home" PATH="$stub_bin:$tool_bin:/usr/bin:/bin" \
  "$chezmoi_bin" --config "$scratch/no-hook.toml" --source "$repo_root" \
  --destination "$production_target" \
  --override-data '{"chezmoi":{"os":"linux","osRelease":{"id":"fedora"}}}' \
  execute-template \
  <"$repo_root/.chezmoiscripts/30-linux/run_after_setup-podman-cluster.sh.tmpl" \
  >"$production_script" 2>"$production_render_err" \
  || fail "the production Podman template did not render: $(cat "$production_render_err")"
[[ ! -s "$production_render_err" ]] \
  || fail "the production Podman render emitted diagnostics: $(cat "$production_render_err")"
bash -n "$production_script" || fail 'the rendered Podman script is not valid shell'
runtime_state="$scratch/runtime-state"
mkdir -p -- "$runtime_state/chezmoi/skips"
podman_source="$scratch/podman-source"
podman_destination="$scratch/podman-destination"
mkdir -p -- "$podman_source/.chezmoidata" "$podman_source/.chezmoitemplates" \
  "$podman_destination"
cp -- "$repo_root/.chezmoidata/.capability-registry.tsv" \
  "$podman_source/.chezmoidata/.capability-registry.tsv"
for shared in capability-cache-identity.sh capabilities.tmpl fingerprint.tmpl skip.sh.tmpl; do
  cp -- "$repo_root/.chezmoitemplates/$shared" "$podman_source/.chezmoitemplates/$shared"
done
cp -- "$repo_root/.chezmoiscripts/30-linux/run_after_setup-podman-cluster.sh.tmpl" \
  "$podman_source/.chezmoitemplates/podman.tmpl"
cat >"$podman_source/dot_podman.tmpl" <<'TEMPLATE'
{{ includeTemplate "podman.tmpl" . }}
TEMPLATE
apply_podman_fixture() {
  local unit=$1 previous_destination=$destination rc
  : >"$log"
  destination="$podman_destination"
  FIXTURE_PODMAN_UNIT="$unit" run_chezmoi \
    "$scratch/hooked.toml" "$podman_source" unavailable present real \
    --override-data '{"chezmoi":{"os":"linux","osRelease":{"id":"fedora"}}}' \
    --force apply >"$scratch/podman.stdout" 2>"$scratch/podman.stderr"
  rc=$?
  destination="$previous_destination"
  return "$rc"
}
reset_cache
rm -rf -- "$podman_destination"
mkdir -p -- "$podman_destination"
apply_podman_fixture unavailable \
  || fail "the Podman unit-absent fixture failed: $(cat "$scratch/podman.stderr")"
podman_absent_render=$(cat "$podman_destination/.podman")
grep -q 'value:podman-socket-unit-present' <<<"$podman_absent_render" \
  || fail 'the absent Podman unit did not reach the rendered fingerprint'
podman_record=("$capability_dir"/*.tsv)
[[ "$(awk -F'\t' '$1 == "podman-socket-unit-present" { print $2 }' "${podman_record[0]}")" == unavailable ]] \
  || fail 'the absent Podman unit did not publish an unavailable capability token'
podman_lifecycle_bin="$scratch/podman-lifecycle-bin"
mkdir -p -- "$podman_lifecycle_bin"
cat >"$podman_lifecycle_bin/systemctl" <<'STUB'
#!/usr/bin/bash
printf '%s\n' "$*" >>"$FIXTURE_PODMAN_RUNTIME_LOG"
case "$*" in
  '--user show-environment') exit 0 ;;
  '--user cat podman.socket') exit "${FIXTURE_PODMAN_RUNTIME_UNIT_RC:-1}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$podman_lifecycle_bin/systemctl"
podman_run() {
  local unit_rc=$1 output=$2 error=$3
  FIXTURE_PODMAN_RUNTIME_UNIT_RC="$unit_rc" \
    FIXTURE_PODMAN_RUNTIME_LOG="$scratch/podman-runtime.log" \
    HOME="$fixture_home" XDG_STATE_HOME="$runtime_state" PATH="$podman_lifecycle_bin" \
    /usr/bin/bash "$podman_destination/.podman" >"$output" 2>"$error"
}
rm -f -- "$scratch/podman-runtime.log"
podman_run 1 "$scratch/podman-absent.out" "$scratch/podman-absent.err" \
  || fail "the absent Podman unit runtime failed: $(cat "$scratch/podman-absent.err")"
grep -q 'podman user socket unit is absent' "$scratch/podman-absent.out" \
  || fail "the absent Podman unit runtime did not defer socket activation: $(cat "$scratch/podman-absent.out")"
! grep -q -- '--user enable --now podman.socket' "$scratch/podman-runtime.log" \
  || fail 'the absent Podman unit runtime enabled the socket'
apply_podman_fixture available \
  || fail "the Podman unit-available fixture failed: $(cat "$scratch/podman.stderr")"
podman_available_render=$(cat "$podman_destination/.podman")
grep -q 'value:podman-socket-unit-present' <<<"$podman_available_render" \
  || fail 'the available Podman unit did not reach the rendered fingerprint'
podman_record=("$capability_dir"/*.tsv)
[[ "$(awk -F'\t' '$1 == "podman-socket-unit-present" { print $2 }' "${podman_record[0]}")" == available ]] \
  || fail 'the available Podman unit did not publish an available capability token'
[[ "$podman_available_render" != "$podman_absent_render" ]] \
  || fail 'the unchanged source did not rerender after the Podman unit appeared'
rm -f -- "$scratch/podman-runtime.log"
podman_run 0 "$scratch/podman-available.out" "$scratch/podman-available.err" \
  || fail "the available Podman unit runtime failed: $(cat "$scratch/podman-available.err")"
grep -q 'enabled --user podman.socket' "$scratch/podman-available.out" \
  || fail 'the available Podman unit runtime did not enable the socket'
grep -q -- '--user enable --now podman.socket' "$scratch/podman-runtime.log" \
  || fail 'the available Podman unit runtime did not call socket activation'

runtime_bin="$scratch/runtime-bin"
mkdir -p -- "$runtime_bin"
cat >"$runtime_bin/systemctl" <<'STUB'
#!/usr/bin/bash
case "$*" in
  '--user show-environment')
    trap '' TERM
    while :; do sleep 1; done
  *) exit 1 ;;
esac
STUB
cat >"$runtime_bin/sudo" <<'STUB'
#!/usr/bin/bash
exit 1
STUB
ln -sf -- "$(type -P sleep)" "$runtime_bin/sleep"
chmod +x "$runtime_bin/systemctl" "$runtime_bin/sudo"
runtime_started=$SECONDS
if ! /usr/bin/timeout 8 env -i HOME="$fixture_home" XDG_STATE_HOME="$runtime_state" PATH="$runtime_bin" \
  CAPABILITY_PROBE_DEADLINE_SECS=1 CAPABILITY_PROBE_TERM_GRACE_SECS=1 \
  /usr/bin/bash "$production_script" >"$scratch/production-runtime.out" \
  2>"$scratch/production-runtime.err"; then
  fail "the rendered Podman script did not converge under a hung user manager: $(cat "$scratch/production-runtime.err")"
fi
runtime_elapsed=$((SECONDS - runtime_started))
((runtime_elapsed <= 5)) \
  || fail "the rendered Podman script exceeded its bounded user-manager deadline (${runtime_elapsed}s)"
grep -q 'user manager bus is unavailable' "$scratch/production-runtime.out" \
  || fail "the rendered Podman script did not take the unavailable user-manager branch: $(cat "$scratch/production-runtime.out")"
[[ ! -s "$scratch/production-runtime.err" ]] \
  || fail "the rendered Podman script emitted diagnostics: $(cat "$scratch/production-runtime.err")"

source_digest_after=$(sha256sum \
  "$repo_root/$registry" "$repo_root/$identity_helper" "$repo_root/$partial" "$repo_root/$hook")
[[ "$source_digest_after" == "$source_digest_before" ]] \
  || fail 'the fixture modified the repository capability sources'

printf '%s\n' 'capability cache fixture passed'
