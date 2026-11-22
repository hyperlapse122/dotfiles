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
    'darwin': 'bd0b168d0ae01351927f31453c0272a61cd099363c3bae38ff717b15b3ddccde',
    'darwin-claude': '0b1de0fd13d9a1c4fe247eb18b8edb617abaf0aa577bbe57531572b33135be15',
    'nixos': 'fad1b116559b04972cc7acc32d2039ff80c8756ff07ee41ac3d92b47ebf8d516',
    'nixos-claude': 'aab6b42398a18efab3fc02621ea9fff8f13e851ec7e92f05804be37df02e5112',
    't3': 'bbf932cf77a01a4da3649661e5f8e99658eb897a4625bb6f27cfdd4c32ddaf3b',
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
            assert 'T3 delegation' in t3 and 'Writing skills' not in t3
            check_receipt(t3, 't3', harness)


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
