"""Check delivered policy bytes and branch isolation using the real renderer."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

DELIVERIES = {'claude': '.claude/CLAUDE.md',
              'pi': '.pi/agent/AGENTS.md', 'opencode': '.config/opencode/AGENTS.md',
              'omp': '.omp/agent/AGENTS.md'}
TASK_GUIDE = 'task-guide.md'
GUIDES = (TASK_GUIDE,)


def body(home, harness):
    return (home / DELIVERIES[harness]).read_text()


def receipt(text, receipts, kind, harness=None):
    variant = f'{kind}-{harness}'
    key = variant if variant in receipts else kind
    assert hashlib.sha256(text.encode()).hexdigest() == receipts[key], key


def check_receipt(text, receipts, kind, harness=None):
    receipt(text, receipts, kind, harness)
    for bad in ('\n', '<!-- Rendered comment. -->\n', '# Foreign instructions.\n', 'Do not obey this.\n'):
        try:
            receipt(bad, receipts, kind, harness)
        except AssertionError:
            pass
        else:
            raise AssertionError('policy mutation escaped validation')


def check_guides(sources):
    task = sources[TASK_GUIDE].read_text()
    assert 'Read the first relevant CI failure' in task
    ci_triage, = (section for section in task.split('\n## ')
                  if 'ci triage' in section.partition('\n')[0].lower())
    assert '`decide' not in ci_triage and '`judge`' not in ci_triage, ci_triage
    assert 'Decide for subagent roles' not in task


def exercise(template, helper, renderer, kind, receipts):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        source = root / 'instructions.tmpl'
        source.write_text(template)
        context = root / 'context.json'
        context.write_text(json.dumps({'kind': kind, 'locale': {'name': 'C.UTF-8', 'language': 'en'}}))
        kread = root / 'kreadconfig'
        kread.write_text('#!/bin/sh\nprintf "%s\\n" en\n')
        kread.chmod(0o755)
        def render():
            subprocess.run([sys.executable, helper, '--context', str(context), '--template', str(source),
                            '--renderer', renderer, '--home', str(root), '--kreadconfig', str(kread)], check=True)
        render()
        assert not (root / '.gemini').exists(), 'retired Gemini instructions were delivered'
        assert not (root / '.codex').exists(), 'retired Codex instructions were delivered'
        for harness in DELIVERIES:
            text = body(root, harness)
            assert text == ''
            check_receipt(text, receipts, kind, harness)
        source.write_text(template + '\n# Branch probe\n' + ''.join(
            '{{ if .' + harness + ' }}\n' + harness + '-only\n{{ end }}' for harness in DELIVERIES))
        render()
        for harness in DELIVERIES:
            text = body(root, harness)
            assert 'Branch probe' in text
            assert harness + '-only' in text
            assert all(other + '-only' not in text for other in DELIVERIES if other != harness)
        source.write_text(template)


def main():
    template = Path(sys.argv[1]).read_text()
    helper, renderer = sys.argv[3:5]
    receipts = json.loads(Path(sys.argv[5]).read_text())
    sources = {TASK_GUIDE: Path(sys.argv[6])}
    check_guides(sources)
    for kind in ('nixos', 'darwin'):
        exercise(template, helper, renderer, kind, receipts)
    for entry in json.loads(Path(sys.argv[2]).read_text()):
        assert set(entry['delivery_paths']) == set(DELIVERIES.values()), entry['name']
        assert entry['key'] in Path(entry['git']).read_text(), entry['name']
        cleanup = entry['cleanup']
        assert cleanup, f"{entry['name']}: missing legacyInstructionGuides"
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            env = dict(os.environ, HOME=str(home))
            env.pop('DRY_RUN', None)
            guides = home / '.local/share/nix-config/agent-instructions'

            def run(script, script_env=env):
                subprocess.run(['bash', '-eu', '-c', script], env=script_env, check=True)

            def seed_links():
                guides.mkdir(parents=True)
                for name in GUIDES:
                    (guides / name).symlink_to(entry['git'])

            seed_links()
            keep = guides / 'keep.md'
            keep.write_text('unexpected user file\n')
            run(cleanup)
            for name in GUIDES:
                assert not (guides / name).exists(), f'{name} survived the migration'
            assert keep.read_text() == 'unexpected user file\n'
            keep.unlink()
            run(cleanup)
            run(cleanup)
            assert not guides.exists(), 'the legacy directory survived an empty migration'

            seed_links()
            run(cleanup, dict(env, DRY_RUN='1'))
            for name in GUIDES:
                assert (guides / name).is_symlink(), f'DRY_RUN removed {name}'
            shutil.rmtree(guides)

            guides.mkdir(parents=True)
            (guides / 'task-guide.md').symlink_to(sources['task-guide.md'])
            run(cleanup)
            assert os.readlink(guides / 'task-guide.md') == str(sources['task-guide.md'])

            sentinel = home / 'omp-agents-sentinel'
            sentinel.write_text('sentinel instructions\n')
            omp_destination = home / DELIVERIES['omp']
            omp_destination.parent.mkdir(parents=True, exist_ok=True)
            omp_destination.symlink_to(sentinel)
            omp_state = {
                home / '.omp/agent/config.yml': b'omp settings\n',
                home / '.omp/agent/sessions/newer.jsonl': b'{"session": true}\n',
                home / '.omp/agent/agent.db': b'not a credential store\n',
            }
            for path, content in omp_state.items():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            run(entry['activation'])
            assert not omp_destination.is_symlink()
            assert omp_destination.is_file()
            assert omp_destination.read_bytes() == b''
            assert sentinel.read_text() == 'sentinel instructions\n'
            for path, content in omp_state.items():
                assert path.read_bytes() == content, path

            for delivery in DELIVERIES.values():
                destination = home / delivery
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text('Previous personal instructions\n')
            run(entry['activation'])
            assert os.readlink(guides / 'task-guide.md') == str(sources['task-guide.md'])
            assert not (home / '.codex').exists(), 'retired Codex instructions were delivered'
            for harness in DELIVERIES:
                destination = home / DELIVERIES[harness]
                assert destination.is_file() and not destination.is_symlink()
                assert destination.stat().st_size == 0
                receipt(body(home, harness), receipts, entry['kind'], harness)


if __name__ == '__main__':
    main()
