"""Check rendered hook commands and reconciliation in a disposable repository."""
import json
from pathlib import Path
import shlex
import subprocess
import sys
from tempfile import TemporaryDirectory


def json_write(path, data):
    path.write_text(json.dumps(data))


def reconcile(root, merger, enabled, disabled):
    settings = root / 'home' / 'settings.json'
    settings.parent.mkdir(exist_ok=True)
    custom_before = {'matcher': 'Write', 'hooks': [{'type': 'command', 'command': 'echo first'}]}
    custom_after = {'matcher': 'Write', 'hooks': [{'type': 'command', 'command': 'echo later'}]}
    custom_handler = {'type': 'command', 'command': 'echo shared'}
    old_handler = {'type': 'command', 'statusMessage': 'Dotfiles agent quality',
                   'command': '/nix/store/' + 'a' * 32 + '-agent-quality-hook/bin/agent-quality-hook old policy'}
    old_post = {'matcher': 'Write', 'hooks': [old_handler]}
    old_stop = {'hooks': [old_handler, custom_handler]}
    seed = {'hooks': {'PreToolUse': [custom_before, old_post, custom_after],
                      'PostToolUse': [custom_before, old_post, custom_after],
                      'Stop': [custom_before, old_stop, custom_after]}, 'other': {'value': 'keep'}}
    json_write(settings, seed)

    def apply(declared):
        subprocess.run([merger, '--settings', settings, '--declared', declared], check=True)
        return json.loads(settings.read_text())

    installed = apply(enabled)
    pre = installed['hooks']['PreToolUse']
    assert pre[0] == custom_before and pre[2] == custom_after
    assert pre[1]['hooks'][0]['command'] != old_handler['command']
    post = installed['hooks']['PostToolUse']
    assert post == [custom_before, custom_after]
    shared = installed['hooks']['Stop'][1]
    assert shared['hooks'] == [custom_handler]
    assert installed['hooks']['Stop'][0] == custom_before and installed['hooks']['Stop'][2] == custom_after
    assert installed['other'] == seed['other']
    assert apply(enabled) == installed
    removed = apply(disabled)
    expected_pre = [custom_before, custom_after]
    assert removed['hooks']['PreToolUse'] == expected_pre
    assert removed['hooks']['PostToolUse'] == post
    assert removed['hooks']['Stop'] == installed['hooks']['Stop']
    reenabled = apply(enabled)
    assert reenabled['hooks']['PreToolUse'] == [custom_before, custom_after, pre[1]]
    assert reenabled['hooks']['PostToolUse'] == post
    assert reenabled['hooks']['Stop'] == installed['hooks']['Stop']
    return installed['hooks']


def exercise(root, hooks):
    project = root / 'fixture with spaces'
    project.mkdir()
    git = ['git', '-C', str(project)]
    subprocess.run(git + ['init', '-q'], check=True)
    marker = project / '.agents/freeze-tests'
    marker.parent.mkdir()
    marker.touch()

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

    result = run('PreToolUse', 'Edit', {'file_path': 'tests/a.txt'})
    assert result.returncode == 2 and 'frozen' in result.stderr, result
    assert run('PreToolUse', 'Edit', {'file_path': 'src/a.txt'}).returncode == 0
    for source, target in (('tests/a.txt', 'src/a.txt'), ('src/a.txt', 'tests/a.txt')):
        patch = {'patchText': f'*** Begin Patch\n*** Update File: {source}\n*** Move to: {target}\n@@\n-x\n+y\n*** End Patch'}
        result = run('PreToolUse', 'patch', patch)
        assert result.returncode == 2 and 'frozen' in result.stderr, result
    marker.unlink()
    assert run('PreToolUse', 'Edit', {'file_path': 'tests/a.txt'}).returncode == 0


if __name__ == '__main__':
    merger, claude_on, claude_off = sys.argv[1:]
    with TemporaryDirectory() as directory:
        root = Path(directory).resolve()
        fixture = root / 'claude'
        fixture.mkdir()
        hooks = reconcile(fixture, merger, claude_on, claude_off)
        exercise(fixture, hooks)
