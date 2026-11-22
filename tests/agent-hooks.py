"""Check rendered hook commands and reconciliation in a disposable repository."""
import json
from pathlib import Path
import shlex
import subprocess
import sys
from tempfile import TemporaryDirectory


def json_write(path, data):
    path.write_text(json.dumps(data))


def reconcile(root, merger, enabled, disabled, preserve_slots):
    settings = root / 'home' / 'settings.json'
    settings.parent.mkdir(exist_ok=True)
    first = {'matcher': 'Write', 'hooks': [{'type': 'command', 'command': 'echo first'}]}
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


def exercise(root, hooks):
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
        "\t@for n in $$(seq 1 75); do echo fixture-$$n >&2; done\n"
        '\t@exit 1\n'
    )
    subprocess.run(git + ['add', '.'], check=True)
    subprocess.run(git + ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
                          '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'], check=True)

    def command(event):
        group = next(group for group in hooks[event] if len(group['hooks']) == 1
                     and group['hooks'][0].get('statusMessage') == 'Dotfiles agent quality')
        return shlex.split(group['hooks'][0]['command'])

    def run(event, tool_name=None, tool_input=None, policy=None, **payload):
        argv = command(event)
        if policy:
            argv[1] = str(policy)
        return subprocess.run(
            argv, input=json.dumps(dict(cwd=str(project), tool_name=tool_name, tool_input=tool_input, **payload)),
            text=True, capture_output=True,
        )

    for shell in ('git commit --no-verify', 'git commit -nm okay', 'SKIP=hook git -C . commit -m okay'):
        result = run('PreToolUse', 'Bash', {'command': shell})
        assert result.returncode == 2 and 'pre-commit' in result.stderr, result
    assert run('PreToolUse', 'Bash', {'command': 'git commit -m "--no-verify"'}).returncode == 0
    assert run('PreToolUse', 'Bash', {'command': 'git status -n'}).returncode == 0

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
    (project / 'new.txt').touch()
    untrusted = run('PostToolUse', 'apply_patch', patch('src/a.txt', 'src/b.txt'), permission_mode='bypassPermissions')
    assert (untrusted.returncode, untrusted.stderr) == (0, '') and not calls.exists(), untrusted
    failure = run('PostToolUse', 'apply_patch', patch('src/a.txt', 'src/b.txt'), policy=policy_path)
    assert failure.returncode == 2 and 'fixture-1' in failure.stderr, failure
    assert len(failure.stderr.splitlines()) == 50, failure
    stop = run('Stop', policy=policy_path)
    assert stop.returncode == 2 and 'fixture-1' in stop.stderr, stop
    exhausted = run('Stop', policy=policy_path, stop_hook_active=True)
    assert (exhausted.returncode, exhausted.stderr) == (0, ''), exhausted
    makefile.unlink()
    missing = run('Stop', policy=policy_path)
    assert (missing.returncode, missing.stderr) == (0, ''), missing
    assert calls.read_text().splitlines() == ['called', 'called']


if __name__ == '__main__':
    merger, claude_on, claude_off, codex_on, codex_off = sys.argv[1:]
    with TemporaryDirectory() as directory:
        root = Path(directory).resolve()
        reconcile(root, merger, claude_on, claude_off, preserve_slots=False)
        codex = reconcile(root, merger, codex_on, codex_off, preserve_slots=True)
        exercise(root, codex)
