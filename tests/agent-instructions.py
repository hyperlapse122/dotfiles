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
              'pi': '.pi/agent/AGENTS.md', 'opencode': '.config/opencode/AGENTS.md'}


GUIDES = ('task-guide.md', 't3-guide.md')


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
    for name, passage in (
        ('task-guide.md', 'Read the first relevant CI failure'),
        ('t3-guide.md', 'Arm the T3 watch with the full PR or MR URL'),
    ):
        assert passage in sources[name].read_text()
    task = sources['task-guide.md'].read_text()
    ci_triage, = (section for section in task.split('\n## ')
                  if 'ci triage' in section.partition('\n')[0].lower())
    assert '`decide' not in ci_triage and '`judge`' not in ci_triage, ci_triage
    guide = sources['t3-guide.md'].read_text()
    assert 'Decide for subagent roles' not in task
    assert 'CE or harness defaults for delegation' in guide
    assert 'cross_model_review_mode: off' in guide
    for retired in ('T3 CE model selection', 'agent-usage --json', 'Fallback order',
                    'Top child rung', 'reasoningEffort'):
        assert retired not in guide, retired


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
            assert harness + '-only' in text
            assert all(other + '-only' not in text for other in DELIVERIES if other != harness)
        source.write_text(template)
        for harness in (None, 'claude', 'pi', 'opencode'):
            context.write_text(json.dumps({'t3': True, **{name: name == harness for name in DELIVERIES}}))
            t3 = subprocess.check_output([renderer, str(source), str(context)], text=True)
            assert t3 == ''
            check_receipt(t3, receipts, 't3', harness)


def main():
    template = Path(sys.argv[1]).read_text()
    helper, renderer = sys.argv[3:5]
    receipts = json.loads(Path(sys.argv[5]).read_text())
    sources = dict(zip(GUIDES, (Path(sys.argv[6]), Path(sys.argv[7]))))
    check_guides(sources)
    for kind in ('nixos', 'darwin'):
        exercise(template, helper, renderer, kind, receipts)
    for entry in json.loads(Path(sys.argv[2]).read_text()):
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
            (guides / 't3-guide.md').write_text('personal copy\n')
            run(cleanup)
            assert os.readlink(guides / 'task-guide.md') == str(sources['task-guide.md'])
            assert (guides / 't3-guide.md').read_text() == 'personal copy\n'

            for delivery in DELIVERIES.values():
                destination = home / delivery
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text('Previous personal instructions\n')
            run(entry['activation'])
            context = home / 't3.json'
            context.write_text('{"t3": true}')
            t3 = subprocess.check_output([renderer, sys.argv[1], str(context)], text=True)
            assert t3 == ''
            assert not (home / '.codex').exists(), 'retired Codex instructions were delivered'
            for harness in DELIVERIES:
                destination = home / DELIVERIES[harness]
                assert destination.is_file() and not destination.is_symlink()
                assert destination.stat().st_size == 0
                receipt(body(home, harness), receipts, entry['kind'], harness)


if __name__ == '__main__':
    main()
