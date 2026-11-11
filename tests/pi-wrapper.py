"""Execute the installed wrapper with fake published keys and native subprocesses."""
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time

with tempfile.TemporaryDirectory() as directory:
    home = Path(directory)
    agent = home / '.pi/agent'
    shutil.copytree(sys.argv[2], agent, symlinks=False)
    for path in [agent, *agent.rglob('*')]:
        path.chmod(path.stat().st_mode | 0o200)
    synthetic = home / 'synthetic'
    exa = home / 'exa'
    synthetic.write_text('FAKE-synthetic')
    exa.write_text('FAKE-exa')
    wrapper = Path(sys.argv[1]).read_text()
    for published, fake in [(sys.argv[3] + '/synthetic_api_key', synthetic), (sys.argv[3] + '/exa_api_key', exa)]:
        assert wrapper.count(published) == 1, 'Host wrapper does not name the published key path'
        wrapper = wrapper.replace(published, str(fake))
    executable = home / 'pi'
    executable.write_text(wrapper)
    executable.chmod(0o700)
    # A project extension uses Pi's native subprocess API after global web tools load.
    project = home / 'project'
    extension = project / '.pi/extensions/probe.ts'
    extension.parent.mkdir(parents=True)
    extension.write_text('''export default function(pi) {
      pi.registerCommand("probe-env", {handler: async(_args,ctx) => {
        const result = await pi.exec("sh", ["-c", "test -z \\\"${EXA_API_KEY+x}\\\""]);
        ctx.ui.notify(result.code === 0 ? "extension-env-clear" : "extension-env-leaked");
      }});
    }''')
    env = dict(os.environ, HOME=directory, PI_CODING_AGENT_DIR=str(agent),
               EXA_API_KEY='FAKE-exa', DOTFILES_PI_EXA_KEY_FILE='/wrong/path')
    process = subprocess.Popen([str(executable), '--offline', '--approve', '--no-session', '--mode', 'rpc'],
        cwd=project, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    pending = b''

    def send(command):
        process.stdin.write((json.dumps(command) + '\n').encode())
        process.stdin.flush()

    def until(predicate):
        global pending
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                event = json.loads(line)
                if predicate(event):
                    return event
            assert selector.select(max(0, deadline-time.monotonic())), 'Wrapper RPC timed out'
            chunk = os.read(process.stdout.fileno(), 65536)
            assert chunk, process.stderr.read().decode()
            pending += chunk
        raise AssertionError('Wrapper RPC timed out')

    try:
        send({'id':'bash','type':'bash','command':'test -z "${EXA_API_KEY+x}" && test "$DOTFILES_PI_EXA_KEY_FILE" = ' + str(exa)})
        response = until(lambda event: event.get('id') == 'bash')
        assert response['success'] and response['data']['exitCode'] == 0, response
        send({'id':'probe','type':'prompt','message':'/probe-env'})
        response = until(lambda event: event.get('type') == 'extension_ui_request' and event.get('method') == 'notify')
        assert response['message'] == 'extension-env-clear', response
        for path in agent.rglob('*'):
            if path.is_file():
                assert b'FAKE-exa' not in path.read_bytes(), 'Exa key persisted into Pi state'
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        selector.close()
