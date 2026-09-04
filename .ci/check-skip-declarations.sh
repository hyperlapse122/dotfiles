#!/usr/bin/env bash
set -uo pipefail

# Fails when the rendered run_onchange_/run_once_ surface stops agreeing with the
# CI-only site matrix (.ci/skip-declaration-site-matrix.yaml): an undeclared
# conditional success exit, a missing/duplicated/malformed/relocated declaration
# sentinel, a declaration whose rendered predicate or continuation no longer
# matches its frozen matrix row, an invalid form/direction, or a
# transient-blocking declaration without its matrix-named cached fingerprint
# value.
#
# WHY RENDERED AND NOT SOURCE. chezmoi records a script that exits 0 as a
# successful run, so a conditional `exit 0` on a precondition path claims a
# convergence it never reached. The claim lives in the RENDERED script — that is
# what chezmoi hashes and runs — and the declaration contract
# (.chezmoitemplates/skip.sh.tmpl) is a partial, so only the rendered output
# shows which consumer actually received which declaration. Every check below
# therefore reads rendered text produced by the real `chezmoi execute-template`
# against this source tree.
#
# WHAT IS IN SCOPE, BY LIFECYCLE. A script's rerun class comes from its chezmoi
# name grammar: run_[once_|onchange_][before_|after_]<name>. `once` and
# `onchange` scripts are the surface whose recorded success can strand work, so
# they are scanned. A plain `run_` script (including U4's `run_after_` extension
# retry jobs) runs on every apply, records nothing, and is therefore out of
# scope — excluded by its lifecycle, never by a filename exception. The matrix
# still accounts for the shared-guard instances inside those always-run scripts:
# they are reported as lifecycle-excluded, so 140 declared instances reconcile as
# rendered + excluded, never as a silently smaller number.
#
# RENDER VARIANTS. One render cannot reach every declared instance: some sites
# sit behind render-time branches (`.chezmoi.os`, a stored LUKS secret). The
# variants below are render inputs only — os/distro data plus, for the secret
# variant, an AES fixture cipher and a keyring answer for exactly the
# config-secrets-key.tmpl read. Every instance must appear in at least one
# variant, and every sentinel found in any variant must be accounted for.
#
# Exit status: 0 clean, 1 declaration findings, 2 enforcement error (missing scan
# root or matrix, render failure, unparsable rendered shell, matrix defect).
#
# Usage: .ci/check-skip-declarations.sh [--fixture] [root]
#   --fixture  the tree is a synthetic fixture, so the frozen production totals
#              (121 owners / 141 instances / 117 + 24) are not asserted; every
#              other check, including matrix self-consistency, still runs.
#   root       source tree to scan; defaults to the current directory.

prog=check-skip-declarations

err() { printf '::error::%s: %s\n' "$prog" "$*" >&2; }

fixture=0
positional=()
while (($#)); do
  case $1 in
    --fixture) fixture=1 ;;
    -h | --help)
      sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      err "unknown option $1"
      exit 2
      ;;
    *) positional+=("$1") ;;
  esac
  shift
done

root=${positional[0]:-.}
if ! root=$(CDPATH='' cd -- "$root" 2>/dev/null && pwd -P); then
  err "cannot resolve root ${positional[0]:-.}"
  exit 2
fi

matrix=$root/.ci/skip-declaration-site-matrix.yaml
scan_root=$root/.chezmoiscripts

# A missing scanned path must fail loudly rather than silently stop enforcing.
if [[ ! -d $scan_root ]]; then
  err "missing scan root $scan_root"
  exit 2
fi
if [[ ! -f $matrix ]]; then
  err "missing site matrix $matrix"
  exit 2
fi

# Resolved to a PATH, not left as a bare command name: `render` below runs
# chezmoi under `env -i` with a sanitized PATH, and `env` looks the program up
# in THAT PATH. A chezmoi installed anywhere but /usr/bin or /bin — CI unpacks
# the locked build into $RUNNER_TEMP/bin and appends it to $GITHUB_PATH — would
# resolve here and then vanish at the render.
if ! chezmoi_bin=$(command -v "${CHEZMOI:-chezmoi}"); then
  err "chezmoi is required to render the scanned surface (set CHEZMOI=/path/to/chezmoi)"
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  err "python3 is required to reconcile the rendered surface"
  exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/$prog.XXXXXX") || {
  err 'cannot create a scratch directory'
  exit 2
}
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch"/{home,target,bin,bin-secret,rendered} || exit 2
: >"$scratch/empty.toml"

# Stub `op` (the AGENTS.md render recipe): newline-free secrets plus the minimal
# item document `onepassword` parses. Secrets never reach a check below; this
# only keeps a render from needing a live 1Password session.
cat >"$scratch/bin/op" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  case $arg in
    whoami) printf 'dummy@example.invalid'; exit 0 ;;
    item) printf '{"id":"stub","title":"stub","fields":[{"id":"username","label":"username","value":"dummy-user"},{"id":"API","label":"API","value":"dummy-secret"}]}'; exit 0 ;;
  esac
done
printf 'dummy-secret'
STUB
chmod 700 "$scratch/bin/op"
cp -- "$scratch/bin/op" "$scratch/bin-secret/op"

# Secret-variant only: answer the one keyring read config-secrets-key.tmpl makes
# (`timeout 10 <chezmoi> secret keyring get ...`) with the fixture key, and exec
# the real timeout for anything else. Without it the stored-LUKS-passphrase
# render-time branch is unreachable and four declared instances could never
# render.
cat >"$scratch/bin-secret/timeout" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  case $arg in
    keyring) printf 'u8-fixture-key\n'; exit 0 ;;
  esac
done
exec /usr/bin/timeout "$@"
STUB
chmod 700 "$scratch/bin-secret/timeout"

render() { # bindir override input output
  local bindir=$1 override=$2 input=$3 output=$4
  env -i HOME="$scratch/home" PATH="$bindir:/usr/bin:/bin" LC_ALL=C \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$root" \
    --destination "$scratch/target" --override-data "$override" \
    execute-template <"$input" >"$output" 2>"$scratch/render.err"
}

linux_data='{"chezmoi":{"os":"linux","osRelease":{"id":"fedora"}}}'
darwin_data='{"chezmoi":{"os":"darwin","osRelease":{"id":"macos"}}}'
ubuntu_data='{"chezmoi":{"os":"linux","arch":"arm64","username":"managed@example.invalid","osRelease":{"id":"ubuntu"}}}'

# The fixture LUKS ciphertext, produced by the same AES implementation the
# consumer decrypts with, keyed by the string the stub keyring returns.
printf '%s' '{{ encryptAES "u8-fixture-key" "u8-fixture-passphrase" }}' >"$scratch/cipher.tmpl"
if ! render "$scratch/bin" "$linux_data" "$scratch/cipher.tmpl" "$scratch/cipher.txt"; then
  err "cannot render the fixture secret cipher: $(tr '\n' ' ' <"$scratch/render.err")"
  exit 2
fi
cipher=$(cat "$scratch/cipher.txt")
if [[ -z $cipher ]]; then
  err 'the fixture secret cipher rendered empty'
  exit 2
fi
secret_data=$(printf '{"chezmoi":{"os":"linux","osRelease":{"id":"fedora"}},"luksPassphraseCipher":"%s"}' "$cipher")

core=$scratch/skip-declaration-core.py
cat >"$core" <<'PYCORE'
"""Rendered skip-declaration reconciliation core.

Two modes:
  plan  <root>                       -> TSV: <rerun-class>\t<source-relative path>
  check <root> <plan> <renders> <fx> -> reconcile rendered output with the matrix

`renders` is a TSV of <source-relative path>\t<variant>\t<rendered file>. The
plan/check split keeps the chezmoi lifecycle grammar in exactly one place: the
shell renders what this file says is in scope, and check re-reads the same plan.
"""
import collections
import hashlib
import re
import sys
from pathlib import Path

SCHEMA = 'skip-declaration-site-matrix-v1'
SENTINEL_TOKEN = 'skip-declaration-v1'
FORMS = ('skip_here', 'skip_step', 'done_here', 'not_applicable')
DIRECTIONS = ('harmless', 'transient-tolerable', 'transient-blocking',
              'operator-blocking')
CONTINUATIONS = ('terminate-script-exit-0', 'terminate-script-exit-1',
                 'terminate-script-render-branch', 'abandon-step-return-0',
                 'abandon-step-inline-notice')
PLACEMENTS = ('new-header-block', 'existing-header-block')
# The R5 boundary U5 froze and U6/U7 executed against. Asserted literally so a
# rendered surface cannot be reconciled against a quietly shrunken oracle.
FROZEN = {'classified_owners': 136, 'rendered_instances': 205,
          'phase_local_instances': 131, 'shared_guard_instances': 74}

RUN_NAME = re.compile(r'^run_(?:(once|onchange)_)?(?:(?:before|after)_)?.+')
SKIP_DIRS = {'.git'}


def rerun_class(name):
    """chezmoi's script name grammar: run_[once_|onchange_][before_|after_]name."""
    m = RUN_NAME.match(name)
    if not m:
        return None
    return m.group(1) or 'always'


def plan(root):
    rows = []
    for path in sorted(Path(root).rglob('run_*')):
        if not path.is_file():
            continue
        if SKIP_DIRS & set(path.relative_to(root).parts):
            continue
        cls = rerun_class(path.name)
        if cls is None:
            continue
        rows.append((cls, path.relative_to(root).as_posix()))
    for cls, rel in rows:
        print(f'{cls}\t{rel}')
    return 0


# --------------------------------------------------------------------------- #
# masking + block structure
# --------------------------------------------------------------------------- #
HEREDOC_WORD = re.compile(r'\s*(-?)\s*(?:"([^"]*)"|\'([^\']*)\'|\\?([A-Za-z_][A-Za-z0-9_]*))')


def mask(text):
    """Blank quoted spans, command substitutions and heredoc bodies so the block
    walker only ever sees shell structure. Comments survive verbatim, which is
    what keeps the generated sentinel readable."""
    out, ctx, heredocs, pending = [], [], [], []
    for raw in text.split('\n'):
        if heredocs:
            delim, dash = heredocs[0]
            if (raw.strip() if dash else raw) == delim:
                heredocs.pop(0)
            out.append('')
            continue
        buf, i, n = [], 0, len(raw)
        while i < n:
            c = raw[i]
            top = ctx[-1] if ctx else 'normal'
            if top == 'single':
                if c == "'":
                    ctx.pop()
                i += 1
                continue
            if top == 'double':
                if c == '\\' and i + 1 < n:
                    i += 2
                    continue
                if c == '$' and raw[i + 1:i + 2] == '(':
                    ctx.append('sub')
                    i += 2
                    continue
                if c == '`':
                    ctx.append('backtick')
                    i += 1
                    continue
                if c == '"':
                    ctx.pop()
                i += 1
                continue
            if top in ('sub', 'backtick'):
                if c == '\\' and i + 1 < n:
                    i += 2
                    continue
                if (c == '<' and raw[i + 1:i + 2] == '<' and raw[i + 2:i + 3] != '<'
                        and raw[i - 1:i] != '<'):
                    m = HEREDOC_WORD.match(raw, i + 2)
                    delim = (m.group(2) or m.group(3) or m.group(4)) if m else None
                    if delim:
                        pending.append((delim, m.group(1) == '-'))
                        i = m.end()
                        continue
                if c == "'":
                    ctx.append('single')
                elif c == '"':
                    ctx.append('double')
                elif c == '$' and raw[i + 1:i + 2] == '(':
                    ctx.append('sub')
                    i += 2
                    continue
                elif c == '(' and top == 'sub':
                    ctx.append('sub')
                elif c == ')' and top == 'sub':
                    ctx.pop()
                elif c == '`' and top == 'backtick':
                    ctx.pop()
                i += 1
                continue
            if c == '\\' and i + 1 < n:
                buf.append('_')
                i += 2
                continue
            if c == "'":
                ctx.append('single')
                buf.append("''")
                i += 1
                continue
            if c == '"':
                ctx.append('double')
                buf.append('""')
                i += 1
                continue
            if c == '`':
                ctx.append('backtick')
                i += 1
                continue
            if c == '$' and raw[i + 1:i + 2] == '(':
                ctx.append('sub')
                buf.append('$()')
                i += 2
                continue
            if (c == '<' and raw[i + 1:i + 2] == '<' and raw[i + 2:i + 3] != '<'
                    and raw[i - 1:i] != '<'):
                m = HEREDOC_WORD.match(raw, i + 2)
                delim = (m.group(2) or m.group(3) or m.group(4)) if m else None
                if delim:
                    pending.append((delim, m.group(1) == '-'))
                    buf.append('<<D')
                    i = m.end()
                    continue
            if c == '#' and (not buf or buf[-1] in (' ', '\t', ';')):
                buf.append(raw[i:])
                break
            buf.append(c)
            i += 1
        out.append(''.join(buf))
        if pending:
            heredocs.extend(pending)
            pending = []
    return out, ctx, heredocs


SENTINEL = re.compile(r'^#\s+' + SENTINEL_TOKEN + r'\s+(\S.*)$')
TERM_PURE = re.compile(r'^(exit|return)(?:\s+(\S+))?$')
TERM_ANY = re.compile(r'(?:^|[;&|)]\s*|\{\s*|\bthen\s+|\belse\s+|\bdo\s+)(exit|return)\b[ \t]*(\S+)?')
FUNCDEF = re.compile(r'^(?:function\s+)?[A-Za-z_][A-Za-z0-9_:.-]*\s*(?:\(\))?\s*\{$')
ARRAY = re.compile(r'^(?:(?:local|declare|readonly|export|typeset)\s+(?:-[a-zA-Z]+\s+)*)?'
                   r'[A-Za-z_][A-Za-z0-9_]*\+?=\(')
CASE_ARM = re.compile(r'^[^()=]*\)')
CONDITIONAL_KINDS = ('if', 'case-arm')


def status_kind(word):
    """Classify a terminator's status argument.

    literal  an explicit numeric status: `exit 0` claims success, `exit 1` is a
             hard failure that can never be mistaken for convergence.
    inherit  a bare `exit`/`return`, which passes the previous command's status
             through — the classic unmarked conditional success exit.
    expr     a variable or arithmetic status (`exit "$rc"`, `return $((...))`),
             which propagates a computed result rather than claiming one.
    """
    if word is None:
        return 'inherit', None
    stripped = word.rstrip(';')
    if re.fullmatch(r'\d+', stripped):
        return 'literal', int(stripped)
    return 'expr', None


class ParseError(Exception):
    pass


def parse_blocks(text):
    """Return the events this guard reconciles — sentinels, terminators, subshell
    ends and branch openings — each carrying the construct stack it sits in and
    the previous significant line. Anything unaccounted raises: a misparse must
    stop the check, never silently stop enforcing."""
    masked, ctx, heredocs = mask(text)
    raws = text.split('\n')
    stack, events, pending, prev = [], [], None, 0
    for idx, line in enumerate(masked, 1):
        s = line.strip()
        if not s:
            continue
        indent = len(raws[idx - 1]) - len(raws[idx - 1].lstrip())
        msent = SENTINEL.match(s)
        if msent:
            events.append({'kind': 'sentinel', 'line': idx, 'fields': msent.group(1),
                           'stack': list(stack), 'indent': indent, 'prev': prev})
            continue
        if s.startswith('#'):
            continue
        if pending:
            if re.search(r'(^|;|\s)' + pending + r'\b', s):
                pending = None
            continue
        here, prev = prev, idx
        head = s.split(None, 1)[0]
        if head == 'fi':
            if not stack or stack[-1]['kind'] != 'if':
                raise ParseError(f'line {idx}: fi closes {stack[-1]["kind"] if stack else "nothing"}')
            events.append({'kind': 'block-end', 'line': idx, 'frame': stack.pop(),
                           'depth': len(stack) + 1})
            continue
        if head == 'esac':
            if stack and stack[-1]['kind'] == 'case-arm':
                events.append({'kind': 'block-end', 'line': idx, 'frame': stack.pop(),
                               'depth': len(stack) + 1})
            if not stack or stack[-1]['kind'] != 'case':
                raise ParseError(f'line {idx}: esac closes {stack[-1]["kind"] if stack else "nothing"}')
            stack.pop()
            continue
        if head == 'done':
            if not stack or stack[-1]['kind'] != 'loop':
                raise ParseError(f'line {idx}: done closes {stack[-1]["kind"] if stack else "nothing"}')
            stack.pop()
            continue
        if s == ';;':
            if not stack or stack[-1]['kind'] != 'case-arm':
                raise ParseError(f'line {idx}: ;; closes {stack[-1]["kind"] if stack else "nothing"}')
            events.append({'kind': 'block-end', 'line': idx, 'frame': stack.pop(),
                           'depth': len(stack) + 1})
            continue
        if s.startswith(')'):
            if not stack or stack[-1]['kind'] not in ('subshell', 'array'):
                raise ParseError(f'line {idx}: ) closes {stack[-1]["kind"] if stack else "nothing"}')
            frame = stack.pop()
            if frame['kind'] == 'subshell':
                events.append({'kind': 'subshell-end', 'line': idx, 'opener': frame,
                               'stack': list(stack), 'tail': s[1:].strip()})
            continue
        if s.startswith('}'):
            if not stack or stack[-1]['kind'] not in ('func', 'group'):
                raise ParseError(f'line {idx}: }} closes {stack[-1]["kind"] if stack else "nothing"}')
            stack.pop()
            continue
        if head == 'elif':
            if not stack or stack[-1]['kind'] != 'if':
                raise ParseError(f'line {idx}: elif outside an if')
            stack[-1] = dict(stack[-1], cond=raws[idx - 1], branch='elif', branch_line=idx)
            events.append({'kind': 'branch', 'line': idx, 'cond': raws[idx - 1],
                           'depth': len(stack)})
            pending = None if re.search(r'(^|;|\s)then$', s) else 'then'
            continue
        if s == 'else':
            if not stack or stack[-1]['kind'] != 'if':
                raise ParseError(f'line {idx}: else outside an if')
            stack[-1] = dict(stack[-1], branch='else', branch_line=idx)
            events.append({'kind': 'branch', 'line': idx, 'cond': stack[-1]['cond'],
                           'depth': len(stack)})
            continue
        case_arm = (CASE_ARM.match(s)
                    if stack and stack[-1]['kind'] == 'case' else None)
        opened_arm = False
        if case_arm and not s.startswith('('):
            stack.append({'kind': 'case-arm', 'line': idx, 'cond': raws[idx - 1],
                          'branch': 'arm', 'branch_line': idx, 'prev': here})
            events.append({'kind': 'branch', 'line': idx, 'cond': raws[idx - 1],
                           'depth': len(stack)})
            opened_arm = True
        term_text = s[case_arm.end():].strip() if opened_arm else s
        for m in TERM_ANY.finditer(s):
            status, code = status_kind(m.group(2))
            events.append({'kind': 'term', 'line': idx, 'word': m.group(1),
                           'status': status, 'code': code,
                           'pure': bool(TERM_PURE.match(term_text)), 'stack': list(stack),
                           'indent': indent, 'text': s, 'prev': here})
        if s.rstrip().endswith(';;'):
            if not stack or stack[-1]['kind'] != 'case-arm':
                raise ParseError(f'line {idx}: ;; closes {stack[-1]["kind"] if stack else "nothing"}')
            events.append({'kind': 'block-end', 'line': idx, 'frame': stack.pop(),
                           'depth': len(stack) + 1})
            continue
        if opened_arm:
            continue
        if s == '(':
            stack.append({'kind': 'subshell', 'line': idx, 'prev': here})
            continue
        if ARRAY.match(s) and s.count('(') > s.count(')'):
            stack.append({'kind': 'array', 'line': idx})
            continue
        if head == 'if':
            if re.search(r'(^|;|\s)fi$', s):
                continue
            stack.append({'kind': 'if', 'line': idx, 'cond': raws[idx - 1],
                          'cond_open': raws[idx - 1], 'branch': 'if',
                          'branch_line': idx, 'prev': here})
            events.append({'kind': 'branch', 'line': idx, 'cond': raws[idx - 1],
                           'depth': len(stack)})
            pending = None if re.search(r'(^|;|\s)then$', s) else 'then'
            continue
        if head == 'case' and re.search(r'\sin$', s):
            stack.append({'kind': 'case', 'line': idx, 'cond': raws[idx - 1]})
            continue
        if head in ('for', 'while', 'until'):
            if re.search(r'(^|;|\s)done$', s):
                continue
            stack.append({'kind': 'loop', 'line': idx})
            pending = None if re.search(r'(^|;|\s)do$', s) else 'do'
            continue
        if FUNCDEF.match(s):
            stack.append({'kind': 'func', 'line': idx})
            continue
        if s.endswith('{'):
            stack.append({'kind': 'group', 'line': idx})
            continue
    if stack:
        raise ParseError('unbalanced at end of script: ' +
                         ', '.join(f'{f["kind"]}@{f["line"]}' for f in stack))
    if ctx:
        raise ParseError(f'unterminated quote or substitution context {ctx}')
    if heredocs:
        raise ParseError(f'unterminated heredoc {heredocs[0][0]}')
    return events


# --------------------------------------------------------------------------- #
# matrix
# --------------------------------------------------------------------------- #
def unquote(value):
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1].replace("''", "'")
    return value


def read_matrix(path, problems):
    """Fixed-shape reader for the subset of YAML the matrix is written in: the CI
    runners carry no PyYAML, and an oracle read through a full parser would still
    need this shape check."""
    top, section, current, pending = {}, None, None, None
    for raw in path.read_text().splitlines():
        if not raw.strip() or raw.lstrip().startswith('#'):
            continue
        if re.match(r'^ {6}- ', raw):
            if pending is None:
                problems.append(f'matrix: list item outside a list: {raw!r}')
                continue
            pending.append(unquote(raw.strip()[2:]))
            continue
        if raw.startswith('  - '):
            current = {}
            top.setdefault(section, []).append(current)
            raw = '    ' + raw[4:]
        if raw.startswith('    '):
            key, _, value = raw.strip().partition(':')
            value = value.strip()
            if current is None:
                problems.append(f'matrix: row field outside a row: {raw!r}')
                continue
            if value == '':
                pending = current[key] = []
            else:
                pending = None
                current[key] = int(value) if re.fullmatch(r'-?\d+', value) else unquote(value)
            continue
        if raw.startswith('  '):
            key, _, value = raw.strip().partition(':')
            value = value.strip()
            top.setdefault(section, {})[key] = int(value) if re.fullmatch(r'-?\d+', value) else unquote(value)
            continue
        key, _, value = raw.partition(':')
        section, current, pending = key.strip(), None, None
        if value.strip():
            top[section] = unquote(value.strip())
    return top


def normalize_predicate(line):
    """The matrix's own rule: drop a leading if/elif, a trailing `; then` and a
    trailing line continuation, then collapse whitespace."""
    s = line.strip()
    s = re.sub(r'^(el)?if\s+', '', s)
    s = re.sub(r'\s*;\s*then$', '', s)
    s = re.sub(r'\s*\\$', '', s)
    return re.sub(r'\s+', ' ', s).strip()


def digest(value):
    return 'sha256:' + hashlib.sha256(value.encode()).hexdigest()


# --------------------------------------------------------------------------- #
# sentinel
# --------------------------------------------------------------------------- #
SENTINEL_KEYS = ('owner', 'instance', 'script', 'site', 'form', 'direction', 'probe',
                 'fingerprint', 'exit')
ID_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
OWNER_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$')
EXITS = {'exit-0': ('exit', 0), 'exit-1': ('exit', 1), 'return-0': ('return', 0)}
FP_LINE = re.compile(r'^#\s+(\S+)\s+([0-9a-f]{64})$')


def parse_sentinel(fields):
    parts = fields.split()
    if len(parts) != len(SENTINEL_KEYS):
        return None, f'expected {len(SENTINEL_KEYS)} fields, got {len(parts)}'
    values = {}
    for key, part in zip(SENTINEL_KEYS, parts):
        head, sep, value = part.partition('=')
        if head != key or not sep or value == '':
            return None, f'expected {key}=<value>, got {part!r}'
        values[key] = value
    if not OWNER_RE.match(values['owner']):
        return None, f'owner {values["owner"]!r} is not one <source>/<site> pair'
    for key in ('script', 'site'):
        if not ID_RE.match(values[key]):
            return None, f'{key} {values[key]!r} is not a safe identity component'
    if values['instance'] != f'{values["script"]}#{values["owner"]}':
        return None, (f'instance {values["instance"]!r} does not name this consumer '
                      f'({values["script"]}#{values["owner"]})')
    if values['form'] not in FORMS:
        return None, f'invalid form {values["form"]!r}'
    is_skip = values['form'] in ('skip_here', 'skip_step')
    if is_skip:
        if values['direction'] not in DIRECTIONS:
            return None, f'invalid direction {values["direction"]!r}'
    elif values['direction'] != 'none':
        return None, f'form {values["form"]} takes no direction, got {values["direction"]!r}'
    blocking = is_skip and values['direction'] == 'transient-blocking'
    if blocking:
        if not ID_RE.match(values['probe']) or values['probe'] == 'none':
            return None, f'transient-blocking declaration needs a probe, got {values["probe"]!r}'
        if values['fingerprint'] != 'required':
            return None, 'transient-blocking declaration must require a fingerprint value'
    else:
        if values['probe'] != 'none':
            return None, f'only transient-blocking consumes a probe, got {values["probe"]!r}'
        if values['fingerprint'] != 'none':
            return None, f'only transient-blocking requires a fingerprint, got {values["fingerprint"]!r}'
    if values['exit'] not in EXITS:
        return None, f'invalid exit token {values["exit"]!r}'
    expected_exit = ('return-0' if values['form'] == 'skip_step' else
                     'exit-1' if blocking is False and is_skip and values['direction'] == 'transient-tolerable'
                     else 'exit-0')
    if values['exit'] != expected_exit:
        return None, (f'form {values["form"]}/{values["direction"]} emits {expected_exit}, '
                      f'sentinel claims {values["exit"]}')
    return values, None


def fingerprint_blocks(text):
    blocks, current = [], []
    for line in text.split('\n'):
        m = FP_LINE.match(line.strip())
        if m:
            current.append(m.group(1))
        elif current:
            blocks.append(current)
            current = []
    if current:
        blocks.append(current)
    return blocks


def declaration_body(raws, sentinel_line, term_line, values):
    """Validate the shell skip.sh.tmpl actually emits between the sentinel and its
    terminator, and that it writes/clears this declaration's own state entry."""
    body = [raws[i - 1].strip() for i in range(sentinel_line + 1, term_line)]
    state = f'chezmoi/skips/{values["script"]}__{values["site"]}'
    # The three record-KEEPING directions share one body shape; only `harmless`
    # (and the two non-deferred forms) clears its entry instead. operator-blocking
    # keeps its record for the same reason the two transient directions do: the
    # host has not converged, so dotfiles-skips must go on reporting it.
    keeps_record = (values['fingerprint'] == 'required'
                    or values['direction'] in ('transient-tolerable', 'operator-blocking'))
    if not body or not body[0].startswith("printf '%s: %s"):
        return 'declaration body does not open with the derived operator notice'
    if keeps_record:
        shape = [r"^printf '%s: %s", r'^mkdir -p "', r"^printf 'v1", r'^> "']
    else:
        shape = [r"^printf '%s: %s", r'^rm -f "']
    if len(body) != len(shape):
        return f'declaration body has {len(body)} lines, expected {len(shape)}'
    for line, want in zip(body, shape):
        if not re.match(want, line):
            return f'declaration body line {line!r} does not match {want}'
    if not any(state in line for line in body):
        return f'declaration body does not name its own state entry {state}'
    return None


def conditional_frames(stack):
    return [f for f in stack if f['kind'] in CONDITIONAL_KINDS]


def enclosing_function(stack):
    return next((f['line'] for f in reversed(stack) if f['kind'] == 'func'), None)


def verdict_functions(events):
    """Functions whose return status is a VERDICT its caller consumes, not an
    abandoned step: they also return a nonzero literal or a computed status.
    `fact_gate` is the standing example — its `return 0` means "the gate holds",
    so it is not an undeclared skip. A function that abandons a step returns 0
    only, and every such site goes through the declaration contract."""
    seen = {}
    for event in events:
        if event['kind'] != 'term' or event['word'] != 'return':
            continue
        func = enclosing_function(event['stack'])
        if func is None:
            continue
        seen.setdefault(func, set()).add((event['status'], event['code']))
    return {func for func, kinds in seen.items()
            if any(kind == 'expr' or (kind == 'literal' and code != 0) for kind, code in kinds)}


def branch_span(events, branch, last_line):
    """The lines a branch controls: from its opener to the next branch or closer
    at the same or shallower depth."""
    for event in events:
        if event['line'] <= branch['line']:
            continue
        if event['kind'] in ('branch', 'block-end') and event['depth'] <= branch['depth']:
            return branch['line'], event['line']
    return branch['line'], last_line


def check(root, plan_path, renders_path, fixture):
    root = Path(root)
    # `defects` are reasons this check cannot enforce anything — a broken oracle,
    # a render that failed, rendered shell it could not parse. Those exit 2 so a
    # silently non-enforcing guard is impossible. `problems` are the findings: a
    # rendered surface that disagrees with a valid oracle.
    problems, defects = [], []
    hard_error_hits = collections.Counter()
    matrix = read_matrix(root / '.ci/skip-declaration-site-matrix.yaml', defects)

    if matrix.get('schema') != SCHEMA:
        defects.append(f'matrix: unexpected schema {matrix.get("schema")!r}')
    if matrix.get('runtime_input') != 'false':
        defects.append('matrix: must declare runtime_input: false')
    owners = matrix.get('owners', [])
    hard_errors = matrix.get('hard_errors', [])
    totals = matrix.get('totals', {})
    fanout = matrix.get('shared_guard_fanout', {})

    # --- matrix self-consistency: recompute, never trust, the frozen digests ---
    # `predicate` is the CANONICAL normalized condition the rendered branch must
    # carry, and its digest is recomputed from it here rather than believed.
    # `anchor`/`anchor_line` stay the raw pre-conversion audit evidence, so they
    # are required to exist but are never used as the comparison string: U6/U7
    # legitimately restructured some branches, and the audit trail records where
    # each site came from.
    by_owner, instances = {}, {}
    for row in owners:
        owner = row.get('owner')
        if owner in by_owner:
            defects.append(f'matrix: duplicate owner {owner}')
        by_owner[owner] = row
        for field in ('template', 'anchor', 'anchor_line', 'predicate', 'predicate_digest',
                      'continuation', 'continuation_digest', 'render_profile', 'form', 'scope',
                      'instances'):
            if field not in row:
                defects.append(f'matrix: owner {owner} is missing {field}')
        if 'predicate' in row:
            if normalize_predicate(row['predicate']) != row['predicate']:
                defects.append(f'matrix: owner {owner} predicate {row["predicate"]!r} is not in '
                                f'normal form ({normalize_predicate(row["predicate"])!r})')
            if digest(row['predicate']) != row['predicate_digest']:
                defects.append(f'matrix: owner {owner} predicate_digest does not match its predicate')
        if 'continuation' in row:
            if row['continuation'] not in CONTINUATIONS:
                defects.append(f'matrix: owner {owner} has unknown continuation {row["continuation"]!r}')
            if digest(row['continuation']) != row['continuation_digest']:
                defects.append(f'matrix: owner {owner} continuation_digest does not match its continuation')
        if row.get('form') not in FORMS:
            defects.append(f'matrix: owner {owner} has invalid form {row.get("form")!r}')
        is_skip = row.get('form') in ('skip_here', 'skip_step')
        direction = row.get('direction')
        if is_skip and direction not in DIRECTIONS:
            defects.append(f'matrix: owner {owner} has invalid direction {direction!r}')
        if not is_skip and direction is not None:
            defects.append(f'matrix: owner {owner} form {row.get("form")} takes no direction')
        blocking = is_skip and direction == 'transient-blocking'
        if blocking:
            if not row.get('probe'):
                defects.append(f'matrix: owner {owner} is transient-blocking without a probe')
            if row.get('fingerprint_placement') not in PLACEMENTS:
                defects.append(f'matrix: owner {owner} has invalid fingerprint_placement '
                                f'{row.get("fingerprint_placement")!r}')
        else:
            if row.get('probe'):
                defects.append(f'matrix: owner {owner} names a probe but is not transient-blocking')
            if row.get('fingerprint_placement'):
                defects.append(f'matrix: owner {owner} declares a fingerprint placement but is not transient-blocking')
        for inst in row.get('instances', []):
            path, sep, inst_owner = inst.partition('#')
            if not sep or inst_owner != owner:
                defects.append(f'matrix: instance {inst} does not name owner {owner}')
                continue
            if inst in instances:
                defects.append(f'matrix: duplicate instance {inst}')
            instances[inst] = row

    for row in hard_errors:
        for field in ('owner', 'template', 'anchor', 'anchor_line', 'predicate',
                      'predicate_digest', 'cause', 'required_outcome'):
            if field not in row:
                defects.append(f'matrix: hard error {row.get("owner")} is missing {field}')
        if 'predicate' in row:
            if normalize_predicate(row['predicate']) != row['predicate']:
                defects.append(f'matrix: hard error {row["owner"]} predicate {row["predicate"]!r} '
                                f'is not in normal form')
            if digest(row['predicate']) != row['predicate_digest']:
                defects.append(f'matrix: hard error {row["owner"]} predicate_digest does not match')
        if row.get('required_outcome') != 'nonzero-exit-with-diagnostic':
            defects.append(f'matrix: hard error {row.get("owner")} does not require a nonzero exit')
        if row.get('owner') in by_owner:
            defects.append(f'matrix: {row.get("owner")} is both a classified owner and a hard error')

    phase_local = sum(1 for row in owners if len(row.get('instances', [])) == 1)
    shared = len(instances) - phase_local
    declared = {'classified_owners': len(owners), 'hard_error_owners': len(hard_errors),
                'rendered_instances': len(instances), 'phase_local_instances': phase_local,
                'shared_guard_instances': shared}
    for key, value in declared.items():
        if totals.get(key) != value:
            defects.append(f'matrix: totals.{key} is {totals.get(key)!r}, rows carry {value}')
    if not fixture:
        for key, value in FROZEN.items():
            if declared[key] != value:
                defects.append(f'matrix: {key} is {declared[key]}, the frozen R5 boundary is {value}')
    for guard, count in fanout.items():
        matches = [row for row in owners if row.get('owner', '').split('/')[0] == guard]
        if len(matches) != 1:
            defects.append(f'matrix: shared_guard_fanout names {guard}, which owns {len(matches)} rows')
            continue
        if len(matches[0].get('instances', [])) != count:
            defects.append(f'matrix: {guard} declares {count} consumer instances but carries '
                            f'{len(matches[0].get("instances", []))}')

    # --- lifecycle surface ------------------------------------------------- #
    plan_rows = [line.split('\t') for line in
                 Path(plan_path).read_text().splitlines() if line.strip()]
    lifecycle = {rel: cls for cls, rel in plan_rows}
    for rel, cls in lifecycle.items():
        if rerun_class(Path(rel).name) != cls:
            defects.append(f'lifecycle: {rel} was planned as {cls}')
    in_scope = {rel for rel, cls in lifecycle.items() if cls in ('once', 'onchange')}
    excluded = {rel for rel, cls in lifecycle.items() if cls == 'always'}

    renders = {}
    for line in Path(renders_path).read_text().splitlines():
        if not line.strip():
            continue
        rel, variant, out = line.split('\t')
        if rel not in in_scope:
            defects.append(f'render: {rel} is not an in-scope lifecycle but was rendered')
        renders[(rel, variant)] = Path(out)
    rendered_rels = {rel for rel, _ in renders}
    for rel in sorted(in_scope - rendered_rels):
        defects.append(f'render: in-scope script {rel} was not rendered')

    for row in owners:
        template = row.get('template')
        if template and not (root / template).exists():
            defects.append(f'matrix: owner {row.get("owner")} names missing template {template}')
    for row in hard_errors:
        template = row.get('template')
        if template and not (root / template).exists():
            defects.append(f'matrix: hard error {row.get("owner")} names missing template {template}')

    # --- rendered surface -------------------------------------------------- #
    # Variants that render a script identically are checked once: the variants
    # exist to reach render-time branches, not to multiply findings. Each
    # instance still records every variant that produced it.
    groups = {}
    for (rel, variant), out in sorted(renders.items()):
        text = out.read_text()
        groups.setdefault((rel, hashlib.sha256(text.encode()).hexdigest()),
                          [text, []])[1].append(variant)

    seen = {}
    for (rel, _), (text, group_variants) in sorted(groups.items()):
        raws = text.split('\n')
        label = f'{rel} [{"+".join(group_variants)}]'
        try:
            events = parse_blocks(text)
        except ParseError as exc:
            defects.append(f'{label}: unparsable rendered shell: {exc}')
            continue
        fp_blocks = fingerprint_blocks(text)
        terms = [e for e in events if e['kind'] == 'term']
        subshell_ends = {e['opener']['line']: e for e in events if e['kind'] == 'subshell-end'}
        verdicts = verdict_functions(events)
        declared_terms = set()
        here = {}

        for event in [e for e in events if e['kind'] == 'sentinel']:
            values, why = parse_sentinel(event['fields'])
            if values is None:
                problems.append(f'{label}:{event["line"]}: malformed sentinel: {why}')
                continue
            owner = values['owner']
            site = f'{label}:{event["line"]} {owner}'
            row = by_owner.get(owner)
            if row is None:
                problems.append(f'{site}: owner is not a matrix owner (unaccounted declaration)')
                continue
            instance = f'{rel}#{owner}'
            if instance not in instances:
                problems.append(f'{site}: {instance} is not a declared instance of this owner '
                                f'(relocated or unaccounted)')
                continue
            if owner in here:
                problems.append(f'{site}: duplicate declaration, already rendered at line {here[owner]}')
                continue
            here[owner] = event['line']
            seen.setdefault(instance, set()).update(group_variants)

            if values['form'] != row.get('form'):
                problems.append(f'{site}: form {values["form"]} does not match matrix form {row.get("form")}')
            matrix_direction = row.get('direction') or 'none'
            if values['direction'] != matrix_direction:
                problems.append(f'{site}: direction {values["direction"]} does not match matrix '
                                f'direction {matrix_direction}')
            matrix_probe = row.get('probe') or 'none'
            if values['probe'] != matrix_probe:
                problems.append(f'{site}: probe {values["probe"]} does not match matrix probe {matrix_probe}')

            # placement: the sentinel must open the branch it declares, either
            # directly or through the subshell wrapper a terminal form needs when
            # the surrounding step must continue.
            frames = conditional_frames(event['stack'])
            branch = frames[-1] if frames else None
            wrapper = event['stack'][-1] if event['stack'] and event['stack'][-1]['kind'] == 'subshell' else None
            if wrapper is not None:
                opens = event['prev'] == wrapper['line']
                anchored = branch is not None and wrapper.get('prev') == branch['branch_line']
            else:
                opens = True
                anchored = branch is not None and event['prev'] == branch['branch_line']
            if not opens:
                problems.append(f'{site}: sentinel does not open its subshell wrapper (relocated)')
            elif branch is not None and not anchored:
                problems.append(f'{site}: sentinel does not open the branch at line '
                                f'{branch["branch_line"]} (relocated)')

            # terminator: the declaration's own emitted exit, in its own scope.
            want_word, want_code = EXITS[values['exit']]
            terminator = next((t for t in terms if t['line'] > event['line']), None)
            if (terminator is None or terminator['line'] - event['line'] > 5
                    or not terminator['pure'] or terminator['word'] != want_word
                    or terminator['status'] != 'literal' or terminator['code'] != want_code
                    or len(terminator['stack']) != len(event['stack'])):
                problems.append(f'{site}: no adjacent {values["exit"]} terminator for this declaration')
                continue
            declared_terms.add(terminator['line'])
            why = declaration_body(raws, event['line'], terminator['line'], values)
            if why:
                problems.append(f'{site}: {why}')

            # continuation: the rendered control flow, then the matrix label.
            if wrapper is not None:
                end = subshell_ends.get(wrapper['line'])
                if end is None:
                    problems.append(f'{site}: subshell wrapper never closes')
                    continue
                follow = next((t for t in terms if t['line'] > end['line']), None)
                if (follow is not None and follow['prev'] == end['line'] and follow['pure']
                        and follow['word'] == 'return' and follow['status'] == 'literal'
                        and follow['code'] == 0
                        and len(follow['stack']) == len(end['stack'])):
                    shape = 'abandon-step-return-0'
                    declared_terms.add(follow['line'])
                else:
                    shape = 'abandon-step-inline-notice'
                accepted = (shape,)
            elif values['exit'] == 'return-0':
                shape = 'abandon-step-return-0'
                # skip_step returns from the step either way: the two matrix
                # labels describe the same rendered control flow.
                accepted = ('abandon-step-return-0', 'abandon-step-inline-notice')
            elif values['exit'] == 'exit-1':
                shape = 'terminate-script-exit-1'
                accepted = (shape,)
            elif branch is None:
                shape = 'terminate-script-render-branch'
                accepted = (shape,)
            else:
                shape = 'terminate-script-exit-0'
                accepted = (shape,)
            if row.get('continuation') not in accepted:
                problems.append(f'{site}: rendered continuation {shape} does not match matrix '
                                f'continuation {row.get("continuation")} '
                                f'({row.get("continuation_digest")})')

            # Predicate: recomputed from the rendered branch and matched against
            # the digest recomputed from the matrix. The matrix records ONE
            # governing condition per site, and a nested conversion can place the
            # declaration under an inner test of that same site (the dockerhub
            # user-bin fallback, the glab/mise chain), so every enclosing
            # condition of this sentinel — each branch's own test and its chain
            # opener — is a candidate. The sentinel still has to OPEN its
            # innermost branch, so this cannot excuse a relocated declaration.
            if row.get('continuation') == 'terminate-script-render-branch':
                if branch is not None:
                    problems.append(f'{site}: declared as a render-time branch but sits inside the '
                                    f'shell conditional at line {branch["branch_line"]}')
                source = (root / row['template']).read_text()
                if not any(normalize_predicate(line) == row['predicate']
                           for line in source.split('\n')):
                    problems.append(f'{site}: render-time predicate {row["predicate"]!r} '
                                    f'({row["predicate_digest"]}) no longer appears in '
                                    f'{row["template"]} (audit anchor {row["anchor"]!r} at line '
                                    f'{row.get("anchor_line")})')
            elif branch is None:
                problems.append(f'{site}: declaration is not inside a conditional branch')
            else:
                candidates = []
                for frame in reversed(frames):
                    for key in ('cond', 'cond_open'):
                        cond = frame.get(key)
                        if cond is None:
                            continue
                        candidate = normalize_predicate(cond)
                        if candidate not in candidates:
                            candidates.append(candidate)
                if not any(digest(candidate) == row.get('predicate_digest')
                           for candidate in candidates):
                    problems.append(f'{site}: rendered predicate {candidates[0]!r} '
                                    f'({digest(candidates[0])}) does not match the matrix '
                                    f'predicate {row.get("predicate")!r} '
                                    f'({row.get("predicate_digest")}); enclosing conditions '
                                    f'{candidates}')

            # blocking pairing: the cached probe value must be hashed into this
            # very script, in the placement the matrix declares.
            if values['fingerprint'] == 'required':
                placement = None
                for block in fp_blocks:
                    if f'value:{values["probe"]}' in block:
                        placement = ('new-header-block'
                                     if all(entry.startswith('value:') for entry in block)
                                     else 'existing-header-block')
                        break
                if placement is None:
                    problems.append(f'{site}: transient-blocking declaration without the cached '
                                    f'fingerprint value value:{values["probe"]}')
                elif placement != row.get('fingerprint_placement'):
                    problems.append(f'{site}: fingerprint value:{values["probe"]} sits in a '
                                    f'{placement}, matrix declares {row.get("fingerprint_placement")}')

        # Undeclared conditional success exits: the failure this contract exists
        # to make impossible. A literal nonzero status is a hard error and always
        # allowed; a propagated status claims nothing; a verdict function's
        # `return 0` is a boolean answer, not an abandoned step.
        for term in terms:
            if term['line'] in declared_terms or term['status'] == 'expr':
                continue
            if term['status'] == 'literal' and term['code'] != 0:
                continue
            if term['word'] == 'return' and enclosing_function(term['stack']) in verdicts:
                continue
            claim = (term['text'] if not term['pure']
                     else f'{term["word"]} {term["code"]}' if term['status'] == 'literal'
                     else term['word'])
            if not term['pure'] or conditional_frames(term['stack']):
                problems.append(f'{label}:{term["line"]}: undeclared conditional success exit '
                                f'({claim}) — declare it through skip.sh.tmpl')

        # Matrix-named hard errors: the only conditional paths allowed to abandon
        # work without a declaration, because a nonzero exit claims no
        # convergence. Each row's canonical predicate must still open a rendered
        # branch, that branch must reach a nonzero literal exit, and it must never
        # be claimed as a declared skip.
        sentinel_lines = [e['line'] for e in events if e['kind'] == 'sentinel']
        branches = [e for e in events if e['kind'] == 'branch']
        for row in hard_errors:
            if row.get('template') != rel:
                continue
            matched = [b for b in branches
                       if digest(normalize_predicate(b['cond'])) == row.get('predicate_digest')]
            hard_error_hits[row['owner']] += len(matched)
            for b in matched:
                start, end = branch_span(events, b, len(raws))
                span_terms = [t for t in terms if start < t['line'] < end]
                if not any(t['status'] == 'literal' and t['code'] != 0 for t in span_terms):
                    problems.append(f'{label}:{b["line"]}: hard error {row["owner"]} ({row["cause"]}) '
                                    f'no longer reaches a nonzero exit '
                                    f'({row.get("required_outcome")})')
                if any(start < s < end for s in sentinel_lines):
                    problems.append(f'{label}:{b["line"]}: hard error {row["owner"]} ({row["cause"]}) '
                                    f'is claimed as a declared skip')

    for row in hard_errors:
        if row.get('template') not in in_scope:
            problems.append(f'hard error {row["owner"]}: template {row.get("template")} is not in '
                            f'the once/onchange surface this check scans')
            continue
        if not hard_error_hits[row['owner']]:
            problems.append(f'hard error {row["owner"]} ({row.get("cause")}): no rendered branch '
                            f'matches its predicate {row.get("predicate")!r} '
                            f'({row.get("predicate_digest")}); the fatal boundary it records is '
                            f'no longer in the rendered surface')

    # --- instance accounting ---------------------------------------------- #
    rendered_instances, lifecycle_excluded, missing = [], [], []
    for inst, row in sorted(instances.items()):
        path = inst.split('#', 1)[0]
        if path in excluded:
            lifecycle_excluded.append(inst)
            if inst in seen:
                problems.append(f'{inst}: declared in an always-run lifecycle but found in the scan')
            continue
        if inst not in seen:
            missing.append(inst)
            continue
        rendered_instances.append(inst)
        profile = row.get('render_profile')
        variants = seen[inst]
        if profile == 'darwin' and 'darwin' not in variants:
            problems.append(f'{inst}: matrix render_profile darwin but it never rendered on darwin')
        if profile != 'darwin' and not (variants - {'darwin'}):
            problems.append(f'{inst}: matrix render_profile {profile} but it only rendered on darwin')
    for inst in missing:
        problems.append(f'{inst}: declared instance never rendered')

    accounted = len(rendered_instances) + len(lifecycle_excluded) + len(missing)
    if accounted != len(instances):
        problems.append(f'accounting: {accounted} of {len(instances)} instances classified')

    print(f'{prog_label}: {len(owners)} matrix owners, {len(hard_errors)} hard errors, '
          f'{len(instances)} declared instances')
    print(f'{prog_label}: scanned {len(in_scope)} once/onchange scripts in '
          f'{len(set(v for _, v in renders))} render variants '
          f'({len(excluded)} always-run scripts excluded by lifecycle)')
    print(f'{prog_label}: {len(rendered_instances)} instances rendered + '
          f'{len(lifecycle_excluded)} lifecycle-excluded + {len(missing)} missing '
          f'= {accounted}')
    print(f'{prog_label}: {len([r for r in hard_errors if hard_error_hits[r["owner"]]])} of '
          f'{len(hard_errors)} matrix-named hard errors verified nonzero and unclaimed at '
          f'{sum(hard_error_hits.values())} rendered branches')
    for inst in lifecycle_excluded:
        print(f'{prog_label}: lifecycle-excluded {inst}')

    for defect in defects:
        print(f'::error::{prog_label}: {defect}', file=sys.stderr)
    for problem in problems:
        print(f'::error::{prog_label}: {problem}', file=sys.stderr)
    if defects:
        print(f'{prog_label}: {len(defects)} enforcement error(s), '
              f'{len(problems)} finding(s); this check could not enforce the contract',
              file=sys.stderr)
        return 2
    if problems:
        print(f'{prog_label}: {len(problems)} finding(s)', file=sys.stderr)
        return 1
    print(f'{prog_label}: rendered declaration surface matches the matrix')
    return 0


prog_label = 'check-skip-declarations'

if __name__ == '__main__':
    mode = sys.argv[1]
    if mode == 'plan':
        sys.exit(plan(sys.argv[2]))
    if mode == 'check':
        sys.exit(check(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == '1'))
    print(f'{prog_label}: unknown mode {mode!r}', file=sys.stderr)
    sys.exit(2)
PYCORE

if ! python3 "$core" plan "$root" >"$scratch/plan.tsv"; then
  err 'cannot enumerate the script surface'
  exit 2
fi

renders=$scratch/renders.tsv
: >"$renders"
n=0
while IFS=$'\t' read -r cls rel; do
  case $cls in once | onchange) ;; *) continue ;; esac
  for variant in linux ubuntu darwin secret; do
    case $variant in
      linux) bindir=$scratch/bin data=$linux_data ;;
      ubuntu) bindir=$scratch/bin data=$ubuntu_data ;;
      darwin) bindir=$scratch/bin data=$darwin_data ;;
      secret) bindir=$scratch/bin-secret data=$secret_data ;;
    esac
    n=$((n + 1))
    out=$scratch/rendered/$n.sh
    if ! render "$bindir" "$data" "$root/$rel" "$out"; then
      err "cannot render $rel in the $variant variant: $(tr '\n' ' ' <"$scratch/render.err")"
      exit 2
    fi
    printf '%s\t%s\t%s\n' "$rel" "$variant" "$out" >>"$renders"
  done
done <"$scratch/plan.tsv"

if [[ ! -s $renders ]]; then
  err 'no once/onchange script rendered; the scanned surface is empty'
  exit 2
fi

python3 "$core" check "$root" "$scratch/plan.tsv" "$renders" "$fixture"
