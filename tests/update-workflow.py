#!/usr/bin/env python3
"""Exercise the merged Actions workflow against disposable Git remotes."""
import json
from pathlib import Path
import subprocess
import sys


def workflow_json(path):
    return json.loads(subprocess.check_output(['yq', '-o=json', '.', str(path)], text=True))


def policy(workflow):
    assert set(workflow['jobs']) == {'update-dependencies', 'watch'}, 'maintenance and drift must have independent jobs'
    assert workflow['permissions'] == {'contents': 'read'}, 'workflow permissions must default to read-only contents'
    assert workflow['jobs']['watch']['permissions'] == {'contents': 'read', 'issues': 'write'}
    dispatch = workflow['on']['workflow_dispatch']['inputs']['part']
    assert dispatch['default'] == 'all'
    assert set(dispatch['options']) == {'all', 'dependencies', 'catalogs', 'drift'}
    assert [entry['cron'] for entry in workflow['on']['schedule']] == ['7,37 * * * *']
    assert workflow['concurrency']['cancel-in-progress'] is False
    maintenance = workflow['jobs']['update-dependencies']
    assert maintenance['timeout-minutes'] >= sum(s.get('timeout-minutes', 0) for s in maintenance['steps']) + 30, 'job timeout leaves no reconciliation and cleanup budget'
    assert 'GH_TOKEN_FOR_UPDATES' not in json.dumps(workflow['jobs']['watch'])
    for job in workflow['jobs'].values():
        checkout = next(s for s in job['steps'] if s.get('uses', '').startswith('actions/checkout@'))
        assert checkout['with']['ref'] == 'main'
        assert checkout['with']['persist-credentials'] is False
        assert 'GH_TOKEN_FOR_UPDATES' not in json.dumps(job.get('env', {}))



# Stubs expose only the external Git/Nix/GitHub boundary. All branch, rebase,
# commit and push effects below use real Git repositories.
STUB = r'''#!PYTHON
import json, os, pathlib, shutil, signal, subprocess, sys
root = pathlib.Path(os.environ['TEST_CONTROL'])
c = json.loads((root / 'control.json').read_text())
real_git = c['git']
args = sys.argv[1:]
name = pathlib.Path(sys.argv[0]).name

def git(*a, cwd=None, capture=True):
    return subprocess.check_output([real_git, *a], cwd=cwd, text=True, stderr=subprocess.DEVNULL).strip()

def event(kind, **data):
    with (root / 'events.jsonl').open('a') as f:
        f.write(json.dumps(dict(kind=kind, **data)) + '\n')

def count(name):
    p = root / name
    n = int(p.read_text()) + 1 if p.exists() else 1
    p.write_text(str(n))
    return n

def move_main(snapshot=False):
    other = c['other']
    subprocess.run([real_git, '-C', other, 'fetch', '-q', 'origin', 'main'], check=True)
    subprocess.run([real_git, '-C', other, 'checkout', '-qB', 'main', 'origin/main'], check=True)
    p = pathlib.Path(other, 'tracked.txt' if c.get('dependency_conflict') else 'home/h82/agents/synthetic-catalog.json' if snapshot else 'concurrent.txt')
    p.write_text('concurrent dependency\n' if c.get('dependency_conflict') else '{"data":[{"id":"other"}]}\n' if c.get('conflict') else '{"data":[{"id":"new"}]}\n' if snapshot else 'concurrent ' + str(count('moves')))
    subprocess.run([real_git, '-C', other, 'add', '.'], check=True)
    subprocess.run([real_git, '-C', other, 'commit', '-qm', 'concurrent main change'], check=True)
    subprocess.run([real_git, '-C', other, 'push', '-q', 'origin', 'main'], check=True)

if name == 'sudo':
    sys.exit(0)
if name == 'gh':
    event('gh', args=args)
    if args[:2] == ['pr', 'list']:
        if c.get('query_error'): sys.exit(1)
        prs = [{'number': 1, 'headRefName': 'unrelated-feature'}]
        if c.get('open_pr'):
            prs.append({'number': 7, 'headRefName': c.get('open_branch', 'update-dependencies-fix')})
        if '--head' in args:
            prs = [pr for pr in prs if pr['headRefName'] == args[args.index('--head') + 1]]
        print(subprocess.check_output(['jq', '-r', args[args.index('--jq') + 1]], input=json.dumps(prs), text=True).strip())
    elif args[:2] in (['pr', 'create'], ['pr', 'edit']):
        body = pathlib.Path(args[args.index('--body-file') + 1]).read_text()
        (root / 'pr-body.md').write_text(body)
    else:
        raise SystemExit('unexpected gh operation: ' + repr(args))
    sys.exit(0)
if name == 'git':
    command = list(args)
    while command and command[0] == '-c': command = command[2:]
    if command and command[0] == 'fetch':
        n = count('fetches')
        if n == c.get('move_fetch'): move_main(c.get('same_snapshot', False) or c.get('conflict', False))
    is_main_push = command and command[0] == 'push' and 'HEAD:refs/heads/main' in command
    if is_main_push:
        n = count('pushes')
        if n <= c.get('race_pushes', 0): move_main()
        head = git('rev-parse', 'HEAD')
        event('push-attempt', sha=head)
        assert os.environ.get('GIT_CONFIG_KEY_1') == 'core.hooksPath'
        assert os.environ.get('GIT_CONFIG_VALUE_1') == '/dev/null'
    result = subprocess.run([real_git, *args])
    if is_main_push and result.returncode == 0: event('pushed', sha=head)
    sys.exit(result.returncode)
if name != 'nix': raise SystemExit('unknown stub: ' + name)
if args[:2] == ['flake', 'update']:
    event('dependency-update')
    if c.get('deps_change', True): pathlib.Path('tracked.txt').write_text('updated dependency\n')
    if c.get('deps_update_fail'):
        pathlib.Path('untracked-output').write_text('failed producer output')
        sys.exit(1)
    sys.exit(0)
if args[:2] == ['run', '.#agent-plugin-release']:
    print('compound-engineering-v2.67.0')
    sys.exit(0)
if args[:2] == ['run', '.#synthetic-models-watch']:
    event('catalog-fetch')
    if c.get('catalog_change', True):
        pathlib.Path(args[args.index('--snapshot') + 1]).write_text('{"data":[{"id":"new"}]}\n')
    sys.exit(1 if c.get('catalog_fetch_fail') else 0)
if args and args[0] == 'run': sys.exit(0)
if args and args[0] in ('fmt', 'flake', 'build'):
    scope = 'catalogs' if any('checks.x86_64-linux.' in a for a in args) else 'dependencies'
    if scope == 'catalogs':
        assert {a for a in args if a.startswith('.#')} == {'.#checks.x86_64-linux.pi', '.#checks.x86_64-linux.synthetic-models'}, 'catalog verification targets changed'
    if scope == 'catalogs' or args[0] == 'fmt': count(scope + '-round')
    round = int((root / (scope + '-round')).read_text())
    event('verify', scope=scope, command=args[0], round=round, sha=git('rev-parse', 'HEAD'))
    if c.get('timeout_dependency_verify') and scope == 'dependencies':
        os.killpg(os.getpgrp(), signal.SIGKILL)
    if os.environ.get('GH_TOKEN_FOR_UPDATES') or os.environ.get('SYNTHETIC_API_KEY'):
        event('secret-leak')
        sys.exit(95)
    print('verification ' + scope + ' ' + args[0] + ' round ' + str(round))
    fail = c.get('verify_fail')
    if fail == scope or (scope == 'dependencies' and fail == args[0]) or (fail == 'after-rebase' and round > 1): sys.exit(1)
    if c.get('interaction_fail') and scope == 'dependencies' and 'new' in pathlib.Path('home/h82/agents/synthetic-catalog.json').read_text(): sys.exit(1)
    event('verified-command', scope=scope, command=args[0], sha=git('rev-parse', 'HEAD'))
    sys.exit(0)
raise SystemExit('unexpected nix arguments: ' + repr(args))
'''

import copy
import os
import re
import shutil
import tempfile


class Fixture:
    def __init__(self, workflow, publisher, verifier, part='all', event='workflow_dispatch', **controls):
        self.temp = tempfile.TemporaryDirectory(prefix='update-workflow-')
        self.root = Path(self.temp.name)
        self.repo = self.root / 'checkout'
        self.origin = self.root / 'origin.git'
        self.other = self.root / 'other'
        self.control = self.root / 'control'
        self.control.mkdir()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.git = shutil.which('git')
        self.env = dict(os.environ, HOME=str(self.home), XDG_CONFIG_HOME=str(self.home), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(self.home / '.gitconfig'))
        self.call('init', '-q', '--bare', str(self.origin))
        self.call('--git-dir', str(self.origin), 'symbolic-ref', 'HEAD', 'refs/heads/main')
        self.call('clone', '-q', str(self.origin), str(self.repo))
        self.configure(self.repo)
        self.call('-C', str(self.repo), 'checkout', '-qb', 'main')
        files = {
            'tracked.txt': 'base dependency\n',
            'flake.nix': '{\n  inputs.compound-engineering-plugin.url = "github:EveryInc/compound-engineering-plugin/compound-engineering-v2.67.0";\n}\n',
            'home/h82/agents/synthetic-catalog.json': '{"data":[{"id":"old"}]}\n',
            'scripts/ci-update-publish': publisher,
            'scripts/ci-update-verify': verifier,
        }
        for name, content in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        self.call('-C', str(self.repo), 'add', '.')
        self.call('-C', str(self.repo), 'commit', '-qm', 'fixture baseline')
        self.call('-C', str(self.repo), 'push', '-q', 'origin', 'main')
        self.base = self.call('-C', str(self.repo), 'rev-parse', 'HEAD').strip()
        self.call('clone', '-q', str(self.origin), str(self.other))
        self.configure(self.other)
        if controls.pop('feature_dispatch', False):
            self.call('-C', str(self.repo), 'checkout', '-qb', 'feature')
            (self.repo / 'feature.txt').write_text('must not publish')
            self.call('-C', str(self.repo), 'add', 'feature.txt')
            self.call('-C', str(self.repo), 'commit', '-qm', 'feature-only work')
        self.reconcile_branch = 'update-dependencies-fix-1729-1'
        self.old_branch = controls.get('open_branch', 'update-dependencies-fix')
        if controls.get('open_pr') or controls.get('query_error') or controls.get('closed_pr'):
            self.call('-C', str(self.other), 'checkout', '-qb', self.old_branch)
            (self.other / 'human-fix').write_text('preserve')
            self.call('-C', str(self.other), 'add', '.')
            self.call('-C', str(self.other), 'commit', '-qm', 'human reconciliation fix')
            self.call('-C', str(self.other), 'push', '-q', 'origin', self.old_branch)
            self.fix_head = self.call('--git-dir', str(self.origin), 'rev-parse', self.old_branch).strip()
        self.controls = dict(controls, git=self.git, other=str(self.other))
        (self.control / 'control.json').write_text(json.dumps(self.controls))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('git', 'nix', 'gh', 'sudo'):
            path = self.bin / name
            path.write_text(STUB.replace('PYTHON', sys.executable, 1))
            path.chmod(0o755)
        self.env.update(PATH=str(self.bin) + os.pathsep + os.environ['PATH'], TEST_CONTROL=str(self.control), GITHUB_WORKSPACE=str(self.repo), RUNNER_TEMP=str(self.root / 'runner'), GITHUB_STEP_SUMMARY=str(self.root / 'summary'), GITHUB_REPOSITORY='example/dotfiles', GITHUB_RUN_ID='1729', GITHUB_RUN_ATTEMPT='1')
        Path(self.env['RUNNER_TEMP']).mkdir()
        self.secrets = {'GH_TOKEN_FOR_UPDATES': 'fake-update-token', 'SYNTHETIC_API_KEY': 'fake-catalog-key'}
        if self.controls.get('missing_token'): del self.secrets['GH_TOKEN_FOR_UPDATES']
        if self.controls.get('missing_catalog_key'): del self.secrets['SYNTHETIC_API_KEY']
        self.workflow = workflow
        self.part = part
        self.event = event
        self.steps = {}
        self.ok = True
        self.cancelled = False
        self.job_ran = False
        self.log = ''

    def call(self, *args):
        return subprocess.check_output([self.git, *args], env=self.env, text=True, stderr=subprocess.DEVNULL)

    def configure(self, repo):
        for key, value in [('user.name', 'Test'), ('user.email', 'test@example.invalid'), ('commit.gpgsign', 'false'), ('core.hooksPath', '/dev/null')]:
            self.call('-C', str(repo), 'config', key, value)

    def value(self, key):
        if key == 'inputs.part': return self.part
        if key == 'github.event_name': return self.event
        if key == 'github.token': return 'fake-read-token'
        if key == 'runner.temp': return self.env['RUNNER_TEMP']
        if key.startswith('secrets.'): return self.secrets.get(key.split('.')[1], '')
        if key.startswith('steps.'):
            _, step, *rest = key.split('.')
            item = self.steps.get(step, {'outcome': 'skipped', 'outputs': {}})
            if rest == ['outcome']: return item['outcome']
            if len(rest) == 2 and rest[0] == 'outputs': return item['outputs'].get(rest[1], '')
        raise AssertionError('unknown Actions context: ' + key)

    def expression(self, expression):
        expression = expression.strip().removeprefix('${{').removesuffix('}}').strip()
        explicit_status = any(x in expression for x in ('cancelled()', 'success()', 'failure()', 'always()'))
        expression = expression.replace('!cancelled()', repr(not self.cancelled)).replace('cancelled()', repr(self.cancelled)).replace('always()', 'True').replace('success()', repr(self.ok)).replace('failure()', repr(not self.ok))
        expression = re.sub(r'\b(?:steps\.[\w-]+\.(?:outputs\.[\w-]+|outcome)|inputs\.part|github\.(?:event_name|token)|runner\.temp|secrets\.[\w-]+)\b', lambda m: repr(self.value(m[0])), expression)
        expression = expression.replace('&&', ' and ').replace('||', ' or ')
        return bool(eval(expression, {'__builtins__': {}}, {})) and (explicit_status or self.ok)

    def expand(self, text):
        return re.sub(r'\$\{\{\s*(.*?)\s*\}\}', lambda m: self.value(m[1].strip()), str(text))

    def run(self):
        job = self.workflow['jobs']['update-dependencies']
        if not self.expression(job.get('if', 'True')): return self
        self.job_ran = True
        env = dict(self.env)
        env.update({key: self.expand(value) for key, value in job.get('env', {}).items()})
        for index, step in enumerate(job['steps']):
            name = step.get('id', str(index))
            if not self.expression(step.get('if', 'True')):
                self.steps[name] = {'outcome': 'skipped', 'outputs': {}}
                continue
            if 'uses' in step:
                if step['uses'].startswith('actions/checkout@'):
                    self.call('-C', str(self.repo), 'fetch', '-q', 'origin')
                    self.call('-C', str(self.repo), 'checkout', '-qB', step['with']['ref'], 'origin/main')
                elif not step['uses'].startswith('cachix/install-nix-action@'):
                    raise AssertionError('unhandled action: ' + step['uses'])
                continue
            output = self.root / ('output-' + name)
            output.touch()
            step_env = dict(env, GITHUB_OUTPUT=str(output))
            step_env.update({key: self.expand(value) for key, value in step.get('env', {}).items()})
            cwd = self.expand(step.get('working-directory', str(self.repo)))
            result = subprocess.run(['bash', '--noprofile', '--norc', '-eo', 'pipefail', '-c', step['run']], cwd=cwd, env=step_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
            self.log += '\n' + step.get('name', name) + ':\n' + result.stdout
            self.steps[name] = {'outcome': 'success' if result.returncode == 0 else 'failure', 'outputs': dict(line.split('=', 1) for line in output.read_text().splitlines() if '=' in line)}
            if result.returncode and not step.get('continue-on-error', False): self.ok = False
            if name == 'catalog' and self.controls.get('cancel_after_catalog'):
                self.cancelled = True
                self.ok = False
        return self

    @property
    def events(self):
        path = self.control / 'events.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def events_of(self, kind):
        return [e for e in self.events if e['kind'] == kind]

    def remote(self, path, ref='main'):
        return self.call('--git-dir', str(self.origin), 'show', f'{ref}:{path}')

    def close(self):
        self.temp.cleanup()


def exercise(workflow, publisher, verifier, name, assertion, **options):
    fixture = Fixture(workflow, publisher, verifier, **options)
    try:
        fixture.run()
        assert not fixture.events_of('secret-leak'), 'verification inherited a secret'
        assertion(fixture)
        assert fixture.call('-C', str(fixture.repo), 'worktree', 'list', '--porcelain').count('worktree ') == 1, 'candidate worktrees remain'
    except Exception:
        print(f'FAILED scenario {name}:\n{fixture.log}', file=sys.stderr)
        raise
    finally:
        fixture.close()
    print('update-workflow: ok - ' + name)


def require(condition, message):
    assert condition, message


def verify_before_push(f):
    verified = {}
    for event in f.events:
        if event['kind'] == 'verified-command':
            key = (event['sha'], event['scope'])
            verified.setdefault(key, set()).add(event['command'])
        if event['kind'] == 'pushed':
            catalog = verified.get((event['sha'], 'catalogs'), set()) == {'build'}
            dependencies = verified.get((event['sha'], 'dependencies'), set()) == {'fmt', 'flake', 'build'}
            require(catalog or dependencies, 'pushed SHA was not verified')


def behavioral_tests(workflow, publisher, verifier):
    def happy(f):
        require(f.ok, 'successful workflow failed')
        require('new' in f.remote('home/h82/agents/synthetic-catalog.json'), 'snapshot was not published')
        require('updated dependency' in f.remote('tracked.txt'), 'dependency was not published')
        verify_before_push(f)
    exercise(workflow, publisher, verifier, 'all parts publish catalog before dependencies', happy)
    for part, selected in [('catalogs', 'catalog-fetch'), ('dependencies', 'dependency-update'), ('drift', None)]:
        def selection(f, part=part, selected=selected):
            require(f.ok, 'selected run failed')
            other = 'dependency-update' if selected == 'catalog-fetch' else 'catalog-fetch'
            require(bool(f.events_of(selected)) if selected else not f.job_ran, 'manual selection did not run its part')
            require(not f.events_of(other), 'manual selection ran another producer')
            require(f.expression(workflow['jobs']['watch']['if']) == (part == 'drift'), 'drift selection gate is wrong')
        exercise(workflow, publisher, verifier, 'manual ' + part, selection, part=part)
    exercise(workflow, publisher, verifier, 'scheduled all-parts run', happy, part='', event='schedule')
    def cancelled(f):
        require(not f.events_of('push-attempt'), 'cancelled run reached publication')
        require(f.steps['prepare_dependencies']['outcome'] == 'skipped', 'cancelled run started another producer')
    exercise(workflow, publisher, verifier, 'cancellation stops publication and cleans candidate worktrees', cancelled, cancel_after_catalog=True)
    def no_changes(f):
        require(f.ok, 'no-change workflow failed')
        require(not f.events_of('verify') and not f.events_of('push-attempt'), 'no-change run verified or pushed')
    exercise(workflow, publisher, verifier, 'no candidates skip verification and publication', no_changes, deps_change=False, catalog_change=False)
    def catalog_failure(f):
        require(not f.ok, 'catalog failure was hidden')
        require('old' in f.remote('home/h82/agents/synthetic-catalog.json'), 'failed catalog leaked')
        require('updated dependency' in f.remote('tracked.txt'), 'catalog failure blocked dependency publication')
    exercise(workflow, publisher, verifier, 'catalog fetch failure does not block dependencies', catalog_failure, catalog_fetch_fail=True)
    exercise(workflow, publisher, verifier, 'missing catalog key does not block dependencies', catalog_failure, missing_catalog_key=True)
    exercise(workflow, publisher, verifier, 'catalog verification failure does not block dependencies', catalog_failure, verify_fail='catalogs')
    def dependency_failure(f):
        require(not f.ok, 'dependency failure was hidden')
        require('new' in f.remote('home/h82/agents/synthetic-catalog.json'), 'dependency failure blocked catalog publication')
        require('base dependency' in f.remote('tracked.txt'), 'failed dependency leaked to main')
        require(any(e['args'][:2] == ['pr', 'create'] for e in f.events_of('gh')), 'dependency failure did not reconcile')
        require('updated dependency' in f.remote('tracked.txt', f.reconcile_branch), 'reconciliation lost dependency candidate')
        diff = f.call('--git-dir', str(f.origin), 'diff', '--name-only', f'main...{f.reconcile_branch}').splitlines()
        require(diff == ['tracked.txt'], 'reconciliation contains catalog or logs: ' + repr(diff))
        logs = f.root / 'runner/updates/dependencies-logs/1'
        require('dependencies fmt' in (logs / 'fmt.log').read_text(), 'format log was lost')
        require('dependencies flake' in (logs / 'check.log').read_text(), 'flake log was lost')
        require('dependencies build' in (logs / 'vm-check.log').read_text() and 'dependencies build' not in (logs / 'check.log').read_text(), 'VM and flake logs were mixed')
    for target in ('fmt', 'flake', 'build'):
        exercise(workflow, publisher, verifier, 'individual dependency verification failure: ' + target, dependency_failure, verify_fail=target)
    exercise(workflow, publisher, verifier, 'catalog/dependency interaction failure retains catalog and reconciles dependencies', dependency_failure, interaction_fail=True)
    def update_failure(f):
        require(not f.ok, 'updater failure was hidden')
        require('new' in f.remote('home/h82/agents/synthetic-catalog.json'), 'failed updater blocked catalog')
        require('base dependency' in f.remote('tracked.txt'), 'partial updater output leaked')
    exercise(workflow, publisher, verifier, 'partial failed updater state stays isolated', update_failure, deps_update_fail=True)
    def preserved(f):
        require(not f.ok, 'verification failure was hidden')
        require(f.call('--git-dir', str(f.origin), 'rev-parse', f.old_branch).strip() == f.fix_head, 'human fix was overwritten')
        require(any(e['args'][:2] == ['pr', 'edit'] for e in f.events_of('gh')), 'open PR did not receive logs')
    exercise(workflow, publisher, verifier, 'existing reconciliation preserves human commits', preserved, verify_fail='fmt', open_pr=True)
    exercise(workflow, publisher, verifier, 'existing numbered reconciliation preserves human commits', preserved, verify_fail='fmt', open_pr=True, open_branch='update-dependencies-fix-1700-1')
    def closed(f):
        require(f.call('--git-dir', str(f.origin), 'rev-parse', f.old_branch).strip() == f.fix_head, 'closed PR branch was overwritten')
        require('updated dependency' in f.remote('tracked.txt', f.reconcile_branch), 'new reconciliation lost dependency candidate')
        require(any(e['args'][:2] == ['pr', 'create'] for e in f.events_of('gh')), 'closed PR prevented new reconciliation')
    exercise(workflow, publisher, verifier, 'closed reconciliation branch is retained while a new PR is created', closed, verify_fail='fmt', closed_pr=True)
    def query_failed(f):
        require(not f.ok, 'failed PR query was hidden')
        require(f.call('--git-dir', str(f.origin), 'rev-parse', 'update-dependencies-fix').strip() == f.fix_head, 'failed query overwrote branch')
        require(not any(e['args'][:2] in (['pr', 'edit'], ['pr', 'create']) for e in f.events_of('gh')), 'failed query wrote PR')
    exercise(workflow, publisher, verifier, 'failed PR lookup is fail-closed', query_failed, verify_fail='fmt', query_error=True)
    def diverged(f):
        require(f.ok, 'diverged publication failed')
        require(len([e for e in f.events_of('verify') if e['scope'] == 'catalogs']) == 2, 'rebase tree was not verified again')
        require('concurrent' in f.remote('concurrent.txt'), 'concurrent main commit lost')
        verify_before_push(f)
    exercise(workflow, publisher, verifier, 'diverged main is rebased and reverified', diverged, part='catalogs', move_fetch=2)
    def rebased_failure(f):
        require(not f.ok, 'post-rebase failure was hidden')
        require(not f.events_of('push-attempt'), 'failed rebased candidate reached push')
        require('old' in f.remote('home/h82/agents/synthetic-catalog.json'), 'failed rebased candidate reached main')
    exercise(workflow, publisher, verifier, 'failed post-rebase verification pushes nothing', rebased_failure, part='catalogs', move_fetch=2, verify_fail='after-rebase')
    def conflict(f):
        require(not f.ok and not f.events_of('push-attempt'), 'conflicted candidate was pushed')
        require(f.steps['publish_catalogs']['outputs']['failure_stage'] == 'rebase', 'conflict was attributed to verification')
        require('other' in f.remote('home/h82/agents/synthetic-catalog.json'), 'concurrent snapshot was lost')
    exercise(workflow, publisher, verifier, 'rebase conflicts abort and push nothing', conflict, part='catalogs', move_fetch=2, conflict=True)
    def rejected(f):
        require(f.ok, 'one rejected push was not recovered')
        require(len(f.events_of('push-attempt')) == 2, 'publisher did not retry exactly once')
        verify_before_push(f)
    exercise(workflow, publisher, verifier, 'rejected push reenters rebase and verification', rejected, part='catalogs', race_pushes=1)
    def twice(f):
        require(not f.ok, 'two rejected pushes succeeded')
        require(len(f.events_of('push-attempt')) == 2 and not f.events_of('pushed'), 'publisher exceeded retry bound or published rejected candidate')
    exercise(workflow, publisher, verifier, 'second rejected push fails without another retry', twice, part='catalogs', race_pushes=2)
    def dependency_recovery(f):
        require(not f.ok and not f.events_of('pushed'), 'failed dependency candidate reached main')
        require(any(e['args'][:2] == ['pr', 'create'] for e in f.events_of('gh')), 'failed dependency candidate did not reconcile')
        require('updated dependency' in f.remote('tracked.txt', f.reconcile_branch), 'reconciliation lost dependency changes')
        diff = f.call('--git-dir', str(f.origin), 'diff', '--name-only', f'main...{f.reconcile_branch}').splitlines()
        require(diff == ['tracked.txt'], 'reconciliation contains unrelated files: ' + repr(diff))
        verify_before_push(f)
    exercise(workflow, publisher, verifier, 'dependency rebase conflict aborts before reconciliation', dependency_recovery, part='dependencies', move_fetch=2, dependency_conflict=True)
    exercise(workflow, publisher, verifier, 'second dependency push rejection retains candidate for reconciliation', dependency_recovery, part='dependencies', race_pushes=2)
    def dependency_timeout(f):
        dependency_recovery(f)
        require(f.steps['publish_dependencies']['outputs']['failure_stage'] == 'verification', 'interruption lost its last publication stage')
        require('Failure stage: verification' in (f.control / 'pr-body.md').read_text(), 'interruption was not reported in reconciliation')
    exercise(workflow, publisher, verifier, 'forced termination during dependency verification retains reconciliation', dependency_timeout, part='dependencies', timeout_dependency_verify=True)
    def no_token(f):
        require(not f.ok, 'missing push token succeeded')
        require(not f.events_of('push-attempt') and 'GH_TOKEN_FOR_UPDATES' in f.log, 'missing token pushed or was not named')
    exercise(workflow, publisher, verifier, 'missing push token never falls back to job token', no_token, part='catalogs', missing_token=True)
    def feature(f):
        require(f.ok, 'feature dispatch failed')
        names=f.call('--git-dir',str(f.origin),'ls-tree','--name-only','main').splitlines()
        require('feature.txt' not in names, 'dispatch published feature commits')
    exercise(workflow, publisher, verifier, 'dispatch checks out main rather than feature commits', feature, part='catalogs', feature_dispatch=True)
    def same_snapshot(f):
        require(f.ok, 'converged snapshot failed')
        require(not f.events_of('push-attempt'), 'snapshot already on main was pushed again')
    exercise(workflow, publisher, verifier, 'snapshot changed on main during run needs no duplicate push', same_snapshot, part='catalogs', move_fetch=2, same_snapshot=True)



def mutation_tests(workflow, publisher, verifier):
    def caught(name, wf, pub, ver, assertion, expected, **options):
        f = Fixture(wf, pub, ver, **options)
        try:
            f.run()
            try:
                assertion(f)
            except AssertionError as error:
                require(expected in str(error), 'mutation failed for another reason: ' + str(error))
            else:
                raise AssertionError('guard mutation survived: ' + name)
        finally:
            f.close()
        print('update-workflow: mutation caught - ' + name)

    def no_push(f):
        require(not f.events_of('push-attempt'), 'failed verification reached push')
    def no_heavy(f):
        require(not f.events_of('verify'), 'unchanged run performed verification')
    def no_duplicate_push(f):
        require(not f.events_of('push-attempt'), 'already-applied snapshot reached push')
    def selected_only(f):
        require(not f.events_of('catalog-fetch'), 'manual dependencies ran catalogs')

    initial = 'verify\nsync_main\n'
    require(initial in publisher, 'missing initial verification mutation anchor')
    caught('initial verification removed', workflow, publisher.replace(initial, 'sync_main\n', 1), verifier, verify_before_push, 'pushed SHA was not verified', part='catalogs')
    anchor = '      verify\n'
    require(anchor in publisher, 'missing rebase verification mutation anchor')
    caught('post-rebase verification removed', workflow, publisher.replace(anchor, '      :\n'), verifier, verify_before_push, 'pushed SHA was not verified', part='catalogs', move_fetch=2)
    call = 'bash "$helpers/ci-update-verify" "$scope" "$logs/$attempt"'
    require(call in publisher, 'missing verification failure mutation anchor')
    caught('verification failure ignored', workflow, publisher.replace(call, call + ' || true'), verifier, no_push, 'failed verification reached push', part='catalogs', verify_fail='catalogs')
    wf = copy.deepcopy(workflow)
    step = next(s for s in wf['jobs']['update-dependencies']['steps'] if s.get('id') == 'publish_catalogs')
    step['if'] = step['if'].replace("steps.catalog.outputs.changed == 'true'", "steps.catalog.outputs.changed != 'unknown'")
    caught('no-change gate removed', wf, publisher, verifier, no_heavy, 'unchanged run performed verification', part='catalogs', catalog_change=False)
    wf = copy.deepcopy(workflow)
    next(s for s in wf['jobs']['update-dependencies']['steps'] if s.get('id') == 'prepare_catalogs')['if'] = '!cancelled()'
    caught('manual selection guard removed', wf, publisher, verifier, selected_only, 'manual dependencies ran catalogs', part='dependencies')
    start = publisher.index('if [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ]; then')
    end = publisher.index('\nfi', start) + len('\nfi')
    caught('already-applied snapshot guard removed', workflow, publisher[:start] + publisher[end:], verifier, no_duplicate_push, 'already-applied snapshot reached push', part='catalogs', move_fetch=2, same_snapshot=True)
    wf = copy.deepcopy(workflow)
    step = next(s for s in wf['jobs']['update-dependencies']['steps'] if s.get('id') == 'publish_catalogs')
    step['if'] = step['if'].replace('!cancelled()', 'always()')
    caught('cancellation guard removed', wf, publisher, verifier, no_push, 'failed verification reached push', cancel_after_catalog=True)
    wf = copy.deepcopy(workflow)
    step = next(s for s in wf['jobs']['update-dependencies']['steps'] if s.get('id') == 'prepare_dependencies')
    anchor = 'git worktree add --detach "$RUNNER_TEMP/updates/dependencies" origin/main'
    require(anchor in step['run'], 'missing candidate isolation mutation anchor')
    step['run'] = step['run'].replace(anchor, 'git worktree add --detach "$RUNNER_TEMP/updates/dependencies" "$(git -C "$RUNNER_TEMP/updates/catalogs" rev-parse HEAD)"')
    def isolated(f):
        require('old' in f.remote('home/h82/agents/synthetic-catalog.json'), 'failed catalog candidate leaked into dependency publication')
    caught('dependency candidate isolation removed', wf, publisher, verifier, isolated, 'failed catalog candidate leaked', verify_fail='catalogs')
    wf = copy.deepcopy(workflow)
    wf['jobs']['watch'].setdefault('env', {})['GH_TOKEN_FOR_UPDATES'] = '${{ secrets.GH_TOKEN_FOR_UPDATES }}'
    try:
        policy(wf)
    except AssertionError:
        print('update-workflow: mutation caught - push credential leaked to drift job')
    else:
        raise AssertionError('drift credential mutation survived')
    wf = copy.deepcopy(workflow)
    wf['jobs']['update-dependencies']['timeout-minutes'] = 180
    try:
        policy(wf)
    except AssertionError as error:
        require('cleanup budget' in str(error), 'timeout mutation failed for another reason: ' + str(error))
    else:
        raise AssertionError('job timeout mutation survived')
    print('update-workflow: mutation caught - job timeout truncates sequential step budget')
    wf = copy.deepcopy(workflow)
    wf['jobs']['update-dependencies'].setdefault('env', {})['UPDATE_ROOT'] = '${{ runner.temp }}/updates'
    with tempfile.TemporaryDirectory(prefix='update-workflow-validation-') as directory:
        path = Path(directory, 'invalid.yml')
        path.write_text(json.dumps(wf))
        result = subprocess.run(['actionlint', '-shellcheck=', '-pyflakes=', str(path)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        require(result.returncode != 0 and 'context "runner" is not allowed here' in result.stdout, 'invalid job context survived workflow validation: ' + result.stdout)
    print('update-workflow: mutation caught - runner context in job environment')


if __name__ == '__main__':
    wf = workflow_json(sys.argv[1])
    policy(wf)
    print('update-workflow: policy passed')
    if len(sys.argv) == 4:
        pub, ver = (Path(arg).read_text() for arg in sys.argv[2:])
        known = json.loads(os.environ.get('UPDATE_CHECK_NAMES', '[]'))
        if known:
            import shlex
            targets = [word for word in shlex.split(ver) if word.startswith('.#checks.x86_64-linux.')]
            assert targets and all(target.removeprefix('.#checks.x86_64-linux.') in known for target in targets), 'catalog verifier refers to a removed check'
        behavioral_tests(wf, pub, ver)
        mutation_tests(wf, pub, ver)
