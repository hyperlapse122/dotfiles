"""Check delivered policy bytes and branch isolation using the real renderer."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

DELIVERIES = {'claude': '.claude/CLAUDE.md', 'codex': '.codex/AGENTS.md',
              'pi': '.pi/agent/AGENTS.md', 'opencode': '.config/opencode/AGENTS.md'}
# Independent content receipts: negation, repetition, deletion and foreign text
# all change the complete normative body, including its order. Claude Code gets
# its conversation language from its own settings, so its render has a receipt
# of its own. Every harness receives the same T3 render.
EXPECTED = {
    'darwin': '4148dccf9299d578a2905cf6add39370f24c088c65d49c98d7276a5a3ae1850b',
    'darwin-claude': 'bc87d2da0e63f4432b271c9b34e64511d34081ea215f36ff44a410a4a6b2248b',
    'nixos': '4148dccf9299d578a2905cf6add39370f24c088c65d49c98d7276a5a3ae1850b',
    'nixos-claude': 'bc87d2da0e63f4432b271c9b34e64511d34081ea215f36ff44a410a4a6b2248b',
    't3': 'fdac77eac9098f73477bf1d9efd24f87c8cb67b17c5016ca828167445ac53d05',
}


def body(home, harness):
    return (home / DELIVERIES[harness]).read_text()


def receipt(text, kind, harness=None):
    variant = f'{kind}-{harness}'
    key = variant if variant in EXPECTED else kind
    assert hashlib.sha256(text.encode()).hexdigest() == EXPECTED[key], key


def check_receipt(text, kind, harness=None):
    receipt(text, kind, harness)
    for bad in (text + '\nForeign instructions.\n', 'Do not ' + text, text + text):
        try:
            receipt(bad, kind, harness)
        except AssertionError:
            pass
        else:
            raise AssertionError('policy mutation escaped validation')


def check_guides(home, native, t3):
    guides = home / '.local/share/nix-config/agent-instructions'
    for text, name, passage in (
        (native, 'task-guide.md', 'Read the first relevant CI failure'),
        (t3, 't3-guide.md', 'Arm the T3 watch with the full PR or MR URL'),
    ):
        assert f'~/.local/share/nix-config/agent-instructions/{name}' in text
        assert passage not in text
        assert passage in (guides / name).read_text()
    task = (guides / 'task-guide.md').read_text()
    ci_triage, = (section for section in task.split('\n## ')
                  if 'ci triage' in section.partition('\n')[0].lower())
    assert '`decide' not in ci_triage and '`judge`' not in ci_triage, ci_triage
    guide = (guides / 't3-guide.md').read_text()
    assert 'Decide for subagent roles' not in task
    assert 'CE or harness defaults for delegation' in guide
    assert 'cross_model_review_mode: off' in guide
    for retired in ('T3 CE model selection', 'agent-usage --json', 'Fallback order',
                    'Top child rung', 'reasoningEffort'):
        assert retired not in guide, retired


def exercise(template, helper, renderer, kind):
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
        for harness in DELIVERIES:
            text = body(root, harness)
            check_receipt(text, kind, harness)
            assert 'T3 delegation' not in text
        source.write_text(template + '\n# Branch probe\n' + ''.join(
            '{{ if .' + harness + ' }}\n' + harness + '-only\n{{ end }}' for harness in DELIVERIES))
        render()
        for harness in DELIVERIES:
            text = body(root, harness)
            assert harness + '-only' in text
            assert all(other + '-only' not in text for other in DELIVERIES if other != harness)
        source.write_text(template)
        for harness in (None, 'claude', 'codex', 'pi', 'opencode'):
            context.write_text(json.dumps({'t3': True, **{name: name == harness for name in DELIVERIES}}))
            t3 = subprocess.check_output([renderer, str(source), str(context)], text=True)
            assert 'T3 task guidance' in t3 and 'Writing and language' not in t3
            check_receipt(t3, 't3', harness)


def main():
    template = Path(sys.argv[1]).read_text()
    helper, renderer = sys.argv[3:5]
    for kind in ('nixos', 'darwin'):
        exercise(template, helper, renderer, kind)
    for entry in json.loads(Path(sys.argv[2]).read_text()):
        assert entry['key'] in Path(entry['git']).read_text(), entry['name']
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            script = entry['activation']
            env = dict(os.environ, HOME=str(home))
            env.pop('DRY_RUN', None)
            subprocess.run(['bash', '-eu', '-c', script], env=env, check=True)
            guides = home / '.local/share/nix-config/agent-instructions'
            guides.parent.mkdir(parents=True, exist_ok=True)
            guides.symlink_to(entry['guides'], target_is_directory=True)
            context = home / 't3.json'
            context.write_text('{"t3": true}')
            t3 = subprocess.check_output([renderer, sys.argv[1], str(context)], text=True)
            for harness in DELIVERIES:
                receipt(body(home, harness), entry['kind'], harness)
                check_guides(home, body(home, harness), t3)


if __name__ == '__main__':
    main()
