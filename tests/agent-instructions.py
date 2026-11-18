"""Check delivered policy bytes and branch isolation using the real renderer."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

DELIVERIES = {'claude': '.claude/CLAUDE.md', 'codex': '.codex/AGENTS.md',
              'antigravity': '.gemini/config/rules',
              'pi': '.pi/agent/AGENTS.md'}
# Independent content receipts: negation, repetition, deletion and foreign text
# all change the complete normative body, including its order. Claude Code gets
# its conversation language from its own settings, so its render has a receipt
# of its own.
EXPECTED = {'darwin': '22dc750d6c26a91e60ca1606ed3240adea8ff9d9cf5e86610651b8a28d12ac14', 'darwin-claude': '32ce19ad264121665936d01a83c7383c5a50a3e722b3f9331a545495561fe002', 'nixos': 'a0e48cc77d546426604ad491ebe69db64fb74b34254dd46c584699ab39facdfa', 'nixos-claude': '202e0c3ecc257fa9f0e8b6454a5b8f549c4812c98fea711bf4127bf9f52868f2', 't3': '24c9a89e1bac22056ae6556a50ef89dbadb6908d50055ecb3699e29f36309079'}


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


def receipt(text, kind, harness=None):
    key = kind + '-claude' if harness == 'claude' else kind
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
        for harness in (None, 'antigravity'):
            context.write_text(json.dumps({'t3': True, **({harness: True} if harness else {})}))
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
                receipt(body(Path(item['path']).parents[len(Path(item['target']).parts)-1], item['delivery']), entry['kind'], item['delivery'])
            continue
        assert entry['key'] in Path(entry['git']).read_text(), entry['name']
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            script = entry['activation']
            env = dict(os.environ, HOME=str(home))
            env.pop('DRY_RUN', None)
            subprocess.run(['bash', '-eu', '-c', script], env=env, check=True)
            for harness in DELIVERIES:
                receipt(body(home, harness), entry['kind'], harness)


if __name__ == '__main__':
    main()
