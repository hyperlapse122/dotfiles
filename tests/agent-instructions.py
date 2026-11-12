"""Check delivered policy bytes and branch isolation using the real renderer."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

DELIVERIES = {'claude': '.claude/CLAUDE.md', 'codex': '.codex/AGENTS.md',
              'antigravity': '.gemini/config/rules', 'grok': '.grok/AGENTS.md',
              'pi': '.pi/agent/AGENTS.md'}
# Independent content receipts: negation, repetition, deletion and foreign text
# all change the complete normative body, including its order.
EXPECTED = {'darwin': '8df40f92f4a4d315efc01fa32f682de5b458801e179750cf6ef80e6b2d5aef09', 'nixos': '3f3236cbbf17e0224c219631a036cdaaa2a1ac29aa518cb870b7addbd1e69a59', 't3': '48ab445d0c747243b3a79c3d750f2604707c6bbb21a0385f363f6e0097c500e9'}


def body(home, harness):
    path = home / DELIVERIES[harness]
    if harness != 'antigravity':
        return path.read_text()
    result = ''
    for item in sorted(path.glob('nix-config-*.md')):
        text = item.read_text()
        assert text.startswith('---\ntrigger: always_on\n---\n\n')
        assert len(item.read_bytes()) < 24000
        result += text.split('---\n\n', 1)[1]
    return result


def receipt(text, kind):
    assert hashlib.sha256(text.encode()).hexdigest() == EXPECTED[kind], kind


def check_receipt(text, kind):
    receipt(text, kind)
    for bad in (text + '\nForeign instructions.\n', 'Do not ' + text, text + text):
        try:
            receipt(bad, kind)
        except AssertionError:
            pass
        else:
            raise AssertionError('policy mutation escaped validation')


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
        for harness in DELIVERIES:
            text = body(root, harness)
            check_receipt(text, kind)
            assert 'T3 delegation' not in text
        source.write_text(template + '\n# Branch probe\n' + ''.join(
            '{{ if .' + harness + ' }}\n' + harness + '-only\n{{ end }}' for harness in DELIVERIES))
        render()
        for harness in DELIVERIES:
            text = body(root, harness)
            assert harness + '-only' in text
            assert all(other + '-only' not in text for other in DELIVERIES if other != harness)
        context.write_text(json.dumps({'t3': True}))
        source.write_text(template)
        t3 = subprocess.check_output([renderer, str(source), str(context)], text=True)
        assert 'T3 delegation' in t3 and 'Writing skills' not in t3
        check_receipt(t3, 't3')


def main():
    template = Path(sys.argv[1]).read_text()
    helper, renderer = sys.argv[5:7]
    for kind in ('nixos', 'darwin'):
        exercise(template, helper, renderer, kind)
    for entry in json.loads(Path(sys.argv[2]).read_text()):
        if entry['kind'] == 'linux':
            for item in entry['paths']:
                receipt(body(Path(item['path']).parents[len(Path(item['target']).parts)-1], item['delivery']), entry['kind'])
            continue
        assert entry['key'] in Path(entry['git']).read_text(), entry['name']
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            script = entry['activation']
            env = dict(os.environ, HOME=str(home))
            env.pop('DRY_RUN', None)
            subprocess.run(['bash', '-eu', '-c', script], env=env, check=True)
            for harness in DELIVERIES:
                receipt(body(home, harness), entry['kind'])


if __name__ == '__main__':
    main()
