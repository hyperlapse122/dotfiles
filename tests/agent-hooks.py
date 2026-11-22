"""Check rendered hook commands and reconciliation in a disposable repository."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
from tempfile import TemporaryDirectory


def json_write(path, data):
    path.write_text(json.dumps(data))


def reconcile(root, merger, enabled, disabled, preserve_slots):
    settings = root / 'home' / 'settings.json'
    settings.parent.mkdir(exist_ok=True)
    first = {'matcher': 'Write', 'hooks': [
        {'type': 'command', 'command': 'echo first', 'statusMessage': 'Dotfiles agent quality'},
    ]}
    later = {'matcher': 'Write', 'hooks': [{'type': 'command', 'command': 'echo later'}]}
    seed = {'hooks': {'PostToolUse': [first]}, 'other': {'value': 'keep'}}
    json_write(settings, seed)

    def apply(declared):
        subprocess.run([merger, '--settings', settings, '--declared', declared], check=True)
        return json.loads(settings.read_text())

    installed = apply(enabled)
    assert installed['hooks']['PostToolUse'][0] == first
    installed['hooks']['PostToolUse'].append(later)
    json_write(settings, installed)
    # A new store path updates the managed command in place.
    previous = json.loads(settings.read_text())
    handler = previous['hooks']['PostToolUse'][1]['hooks'][0]
    handler['command'] = re.sub(r'/nix/store/[a-z0-9]{32}-', '/nix/store/' + 'a' * 32 + '-',
                                handler['command'], count=1)
    assert previous != installed
    json_write(settings, previous)
    assert apply(enabled) == installed

    removed = apply(disabled)
    groups = removed['hooks']['PostToolUse']
    assert groups[0] == first and groups[-1] == later
    assert len(groups) == (3 if preserve_slots else 2)
    if preserve_slots:
        assert groups[1]['hooks'] == []
    assert removed['other'] == seed['other']
    if preserve_slots:
        assert apply(enabled) == installed
    return installed['hooks']


def exercise(root, hooks, harness):
    project = root / 'fixture with spaces'
    project.mkdir()
    git = ['git', '-C', str(project)]
    subprocess.run(git + ['init', '-q'], check=True)
    marker = project / '.agents/freeze-tests'
    marker.parent.mkdir()
    marker.touch()
    calls = root / 'calls'
    makefile = project / 'Makefile'
    makefile.write_text(
        'agent-check:\n'
        f'\t@echo called >> {shlex.quote(str(calls))}\n'
    )
    (project / 'fixture.py').touch()
    (project / '.gitattributes').write_text('fixture.py filter=fixture\n')
    subprocess.run(git + ['add', '.'], check=True)
    subprocess.run(git + ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
                          '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'], check=True)

    def command(event):
        group = next(group for group in hooks[event] if len(group['hooks']) == 1
                     and '/bin/agent-quality-hook ' in group['hooks'][0]['command'])
        return shlex.split(group['hooks'][0]['command'])

    def run(event, tool_name=None, tool_input=None, policy=None, **payload):
        argv = command(event)
        if policy:
            argv[1] = str(policy)
        return subprocess.run(
            argv, input=json.dumps(dict(cwd=str(project), tool_name=tool_name, tool_input=tool_input, **payload)),
            text=True, capture_output=True,
        )

    for shell in ('git commit --no-verify', 'git commit -nm okay', 'SKIP=hook git -C . commit -m okay',
                  'git commit -nuall', 'git commit -unormal --no-verify', 'git commit -u -n'):
        result = run('PreToolUse', 'Bash', {'command': shell})
        assert result.returncode == 2 and 'pre-commit' in result.stderr, result
    for shell in ('git commit -m "--no-verify"', 'git status -n', 'git commit -u',
                  'git commit -uno', 'git commit -unormal', 'git commit -uall', 'git commit -auno'):
        result = run('PreToolUse', 'Bash', {'command': shell})
        assert result.returncode == 0, result

    def patch(source, target):
        return {'command': f'*** Begin Patch\n*** Add File: other.txt\n+fine\n'
                           f'*** Update File: {source}\n*** Move to: {target}\n@@\n-old\n+new\n'
                           '*** End Patch'}

    for source, target in [('tests/a.txt', 'src/a.txt'), ('src/a.txt', 'tests/a.txt')]:
        result = run('PreToolUse', 'apply_patch', patch(source, target))
        assert result.returncode == 2 and 'frozen' in result.stderr, result
    assert run('PreToolUse', 'apply_patch', patch('src/a.txt', 'src/b.txt')).returncode == 0
    marker.unlink()
    assert run('PreToolUse', 'apply_patch', patch('src/a.txt', 'tests/a.txt')).returncode == 0

    policy_path = root / 'authorized.json'
    opts = json.loads(Path(command('Stop')[1]).read_text())
    json_write(policy_path, dict(opts, trustedProjects=[str(project)]))
    marker.touch()
    clean = run('Stop', policy=policy_path)
    assert (clean.returncode, clean.stderr) == (0, '') and not calls.exists(), clean
    # The ordinary Git status and the old project task could each execute commands here.
    shell = f'echo called >> {shlex.quote(str(calls))}'
    subprocess.run(git + ['config', 'core.fsmonitor', shell], check=True)
    subprocess.run(git + ['config', 'filter.fixture.clean', shell + '; cat'], check=True)
    (project / 'fixture.py').write_text('eval(value)\n')
    outside = root / 'outside.py'
    outside.write_text('eval(value)\n')
    (project / 'link.py').symlink_to(outside)
    tool = ('Write', {'file_path': 'fixture.py'}) if harness == 'claude' else (
        'apply_patch', {'command': '*** Update File: fixture.py\n'})
    untrusted = run('PostToolUse', *tool, permission_mode='bypassPermissions')
    assert (untrusted.returncode, untrusted.stdout, untrusted.stderr) == (0, '', ''), untrusted
    advisory = run('PostToolUse', *tool, policy=policy_path, permission_mode='default')
    assert advisory.returncode == 0 and not advisory.stderr, advisory
    output = json.loads(advisory.stdout)
    assert set(output) == {'hookSpecificOutput'}, output
    assert output['hookSpecificOutput'] == {
        'hookEventName': 'PostToolUse',
        'additionalContext': 'agent-check: warning "fixture.py":1 eval_injection',
    }, output
    linked = ('Write', {'file_path': 'link.py'}) if harness == 'claude' else (
        'apply_patch', {'command': '*** Update File: link.py\n'})
    skipped = run('PostToolUse', *linked, policy=policy_path)
    assert (skipped.returncode, skipped.stdout, skipped.stderr) == (0, '', ''), skipped
    stop = run('Stop', policy=policy_path, permission_mode='default')
    assert stop.returncode == 2 and 'shell tool' in stop.stderr, stop
    exhausted = run('Stop', policy=policy_path, stop_hook_active=True)
    assert (exhausted.returncode, exhausted.stderr) == (0, ''), exhausted
    assert not calls.exists(), 'automatic quality hooks executed a checkout command'


if __name__ == '__main__':
    merger, claude_on, claude_off, codex_on, codex_off = sys.argv[1:]
    with TemporaryDirectory() as directory:
        root = Path(directory).resolve()
        for harness, on, off in (('claude', claude_on, claude_off), ('codex', codex_on, codex_off)):
            fixture = root / harness
            fixture.mkdir()
            hooks = reconcile(fixture, merger, on, off, preserve_slots=harness == 'codex')
            exercise(fixture, hooks, harness)
