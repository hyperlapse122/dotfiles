#!/usr/bin/env python3
import json
import os
from collections import deque
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
            os.set_blocking(child.stdin.fileno(), False)
            pending = []
            outgoing = deque()
            input_open = True
            writing = False
            running = True
            while running:
                for key, _ in selector.select():
                    if key.data == 'write':
                        written = os.write(key.fd, outgoing[0])
                        outgoing[0] = outgoing[0][written:]
                        if not outgoing[0]:
                            outgoing.popleft()
                        if not outgoing:
                            selector.unregister(child.stdin)
                            writing = False
                            if not input_open:
                                child.stdin.close()
                        continue
                    data = os.read(key.fd, 65536)
                    if key.data == 'output':
                        if not data:
                            running = False
                            break
                        sys.stdout.buffer.write(data)
                        sys.stdout.buffer.flush()
                        continue
                    parts = data.split(b'\n')
                    for part in parts[:-1]:
                        pending.append(part)
                        line = b''.join(pending) + b'\n'
                        pending.clear()
                        if line.strip():
                            outgoing.append(memoryview(with_instructions(line)))
                    if parts[-1]:
                        pending.append(parts[-1])
                    if not data:
                        line = b''.join(pending)
                        if line.strip():
                            outgoing.append(memoryview(with_instructions(line)))
                        input_open = False
                        selector.unregister(key.fileobj)
                        if not outgoing:
                            child.stdin.close()
                    if outgoing and not writing:
                        selector.register(child.stdin, selectors.EVENT_WRITE, 'write')
                        writing = True
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
