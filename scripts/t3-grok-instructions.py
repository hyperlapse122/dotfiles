#!/usr/bin/env python3
"""Attach the managed T3 policy to Grok's ACP task context."""

import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys


POLICY_URI = 't3-instructions://dotfiles/grok'


def with_instructions(line):
    message = json.loads(line)
    if not isinstance(message, dict) or message.get('method') != 'session/prompt':
        return line
    prompt = message['params']['prompt']
    if not isinstance(prompt, list):
        raise ValueError('Invalid prompt')
    policy = (Path.home() / '.t3/userdata/instructions/grok.md').read_text(encoding='utf-8')
    if not policy.strip():
        raise ValueError('Empty policy')
    message['params']['prompt'] = [block for block in prompt if not (
        isinstance(block, dict) and block.get('type') == 'resource'
        and isinstance(block.get('resource'), dict)
        and block['resource'].get('uri') == POLICY_URI
    )] + [{'type': 'resource', 'resource': {
        'uri': POLICY_URI, 'mimeType': 'text/markdown', 'text': policy,
    }}]
    return json.dumps(message, ensure_ascii=False).encode('utf-8') + b'\n'


def main():
    arguments = sys.argv[1:]
    if 'agent' not in arguments or 'stdio' not in arguments:
        os.execvp('grok', ['grok', *arguments])
    child = subprocess.Popen(['grok', *arguments], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, lambda received, frame: child.send_signal(received))
    failed = False
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(sys.stdin.buffer, selectors.EVENT_READ, 'input')
            selector.register(child.stdout, selectors.EVENT_READ, 'output')
            pending = b''
            running = True
            while running:
                for key, _ in selector.select():
                    data = os.read(key.fd, 65536)
                    if key.data == 'output':
                        if not data:
                            running = False
                            break
                        sys.stdout.buffer.write(data)
                        sys.stdout.buffer.flush()
                        continue
                    pending += data
                    while b'\n' in pending:
                        line, pending = pending.split(b'\n', 1)
                        if line.strip():
                            child.stdin.write(with_instructions(line + b'\n'))
                            child.stdin.flush()
                    if not data:
                        if pending.strip():
                            child.stdin.write(with_instructions(pending))
                            child.stdin.flush()
                        child.stdin.close()
                        selector.unregister(key.fileobj)
    except BrokenPipeError:
        pass
    except (OSError, ValueError, KeyError, TypeError):
        failed = True
        print('T3 Grok instruction delivery failed. Reapply configuration and restart T3.', file=sys.stderr)
    finally:
        if not child.stdin.closed:
            try:
                child.stdin.close()
            except BrokenPipeError:
                pass
        if failed and child.poll() is None:
            child.terminate()
        try:
            status = child.wait(timeout=10 if failed else None)
        except subprocess.TimeoutExpired:
            child.kill()
            status = child.wait()
    if failed:
        return 1
    if status < 0:
        signal.signal(-status, signal.SIG_DFL)
        os.kill(os.getpid(), -status)
    return status


if __name__ == '__main__':
    raise SystemExit(main())
