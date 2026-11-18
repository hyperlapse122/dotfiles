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
EXPECTED = {'darwin': '0d0e238eddb0d9ccd9e5b7cc168ddac42ce3324fcb5df3b23ff15f25fb770236', 'darwin-claude': 'c4da0fcf3cb14b5b8e2cbbd79232ff99dd675d75c02d3d5bfbfb3bf86b866b2c', 'nixos': 'c67e4297c6dfc1ecd492ae6ee70a5e8b228392a259bbe9abcda439f4cdd6df90', 'nixos-claude': 'c16f0173e7f6304cdb8e05b21b2d768e9b51e9d370f8c0cf8b9effe35bac9ad4', 't3': 'a8f041277add6e5aac8ce490dcc347d17353e8919dd522b47e5442e68c41e811'}


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
        for harness in (None, 'claude', 'codex', 'pi'):
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
