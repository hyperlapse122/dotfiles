"""Exercise Darwin provisioning with fake tools; never change the host."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

XCODE, CONTAINER, STATE = map(Path, sys.argv[1:4])
ACTIVATIONS = Path(sys.argv[4]) if len(sys.argv) > 4 else None
sys.argv[1:] = []
spec = importlib.util.spec_from_file_location('macos_xcode', XCODE)
x = importlib.util.module_from_spec(spec)
spec.loader.exec_module(x)


class Provisioning(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'log'
        self.env = os.environ | {'PATH': str(self.bin) + ':' + os.environ['PATH'],
                                 'HOME': str(self.root), 'LOG': str(self.log)}

    def stub(self, name, body):
        p = self.bin / name
        p.write_text('#!' + sys.executable + '\n' + body)
        p.chmod(0o755)

    def identity(self):
        p = self.root / 'key.txt'
        p.write_text('fake identity')
        p.chmod(0o600)
        return p

    def test_account_environment_and_identity(self):
        self.stub('sops', '''import json, os, sys
assert sys.argv[1:4] == ['--decrypt', '--output-type', 'json']
assert sys.argv[4].endswith('/apple-account.yaml')
assert os.environ['SOPS_AGE_KEY_FILE'].endswith('/key.txt')
assert 'XCODES_PASSWORD' not in os.environ
print(json.dumps({'username': 'fake-user', 'password': 'fake-password'}))
''')
        self.stub('xcodes', '''import json, os, sys
assert os.environ['XCODES_USERNAME'] == 'fake-user'
assert os.environ['XCODES_PASSWORD'] == 'fake-password'
assert all('fake-' not in a for a in sys.argv)
open(os.environ['LOG'], 'w').write(json.dumps(sys.argv[1:]))
# Deliberately echo the fake credentials to test redaction.
print('fake-user fake-password')
''')
        identity = self.identity()
        source = self.root / 'apple-account.yaml'
        source.write_text('fake ciphertext')
        owner = pwd.getpwuid(os.getuid()).pw_name
        @contextlib.contextmanager
        def terminal():
            with open(os.devnull, 'rb') as f:
                yield f, {}
        release = {'name': 'Xcode', 'version': {'number': '27.0', 'build': 'A123', 'release': {'beta': 2}}, 'requires': '26.0'}
        import io
        out = io.StringIO()
        candidate = self.root / 'Xcode.app'
        with patch.dict(os.environ, self.env), patch.object(x, 'terminal_input', terminal):
            with contextlib.redirect_stdout(out), patch.object(x, 'fetch_catalog', return_value=[release]), patch.object(x, 'host_version', return_value='26.0'), patch.object(x, 'installed_candidate', side_effect=[None, candidate]), patch.object(x, 'verify_candidate') as verify, patch.object(x, 'run_command', return_value=subprocess.CompletedProcess([], 0, str(candidate / 'Contents/Developer'))):
                x.update(source, identity, owner)
                verify.assert_called_once_with(candidate)
            self.assertEqual(json.loads(self.log.read_text())[:2], ['install', '27.0 Beta 2'])
            self.assertNotIn('fake-password', out.getvalue())
            self.assertNotIn('fake-user', out.getvalue())
            self.log.unlink()
            for mode in (0o644, 0o400):
                identity.chmod(mode)
                with self.assertRaises(x.XcodeError):
                    x.read_account(source, identity, owner)
            identity.chmod(0o600)
            with patch.object(x.pwd, 'getpwnam', return_value=type('User', (), {'pw_uid': os.getuid() + 1})()):
                with self.assertRaises(x.XcodeError):
                    x.read_account(source, identity, owner)
            link = self.root / 'link'
            link.symlink_to(identity)
            with self.assertRaises(x.XcodeError):
                x.read_account(source, link, owner)
            self.assertFalse(self.log.exists())
            # Activation names the file by its store path; flake evaluation
            # already copies the ciphertext there.
            self.assertEqual(x.read_account(Path('/nix/store/fake/apple-account.yaml'), identity, owner),
                             {'username': 'fake-user', 'password': 'fake-password'})

    def test_release_selection_and_first_launch(self):
        def release(n, channel, seq=1):
            return {'name': 'Xcode', 'version': {'number': n, 'build': 'A1', 'release': {channel: seq}}, 'requires': '26.0'}
        self.assertEqual(x.latest([release('26.0','release'), release('27.0','beta'), release('27.0','rc')])['version']['release'], {'rc': 1})
        events = []
        def run(args, **kwargs):
            events.append(args)
            code = 1 if args[-1] == '-checkFirstLaunchStatus' and len(events) == 3 else 0
            return subprocess.CompletedProcess(args, code, '/fake/tool')
        with patch.object(x, 'run_command', side_effect=run), patch.object(x, 'run_interactive', side_effect=lambda args, **kw: events.append(args)):
            x.verify_candidate(Path('/fake/Xcode.app'))
        self.assertLess(next(i for i,e in enumerate(events) if '-license' in e), next(i for i,e in enumerate(events) if '-runFirstLaunch' in e))
        self.assertEqual(sum('-checkFirstLaunchStatus' in e for e in events), 2)
        self.assertTrue(any('--show-sdk-path' in e for e in events))

    def test_container_states(self):
        script = self.root / 'macos-container.sh'
        shutil.copy(CONTAINER, script)
        shutil.copy(STATE, self.root / 'macos-container-state.sh')
        self.stub('container', '''import json, os, sys
from pathlib import Path
p=Path(os.environ['HOME'])/'running'
a=sys.argv[1:]
with open(os.environ['LOG'], 'a') as f: f.write('container '+ ' '.join(a)+'\\n')
if a == ['system','status','--format','json']:
 print(json.dumps({'status': 'running' if p.exists() else 'not running'})); sys.exit(0 if p.exists() else 1)
if a == ['system','start','--disable-kernel-install']: p.touch()
elif a != ['system','kernel','set','--recommended','--force']: sys.exit(10)
''')
        self.stub('launchctl', '''import os, sys
with open(os.environ['LOG'], 'a') as f: f.write('launchctl ' + ' '.join(sys.argv[1:]) + '\\n')
assert sys.argv[1:] == ['print', 'gui/' + str(os.getuid())]
sys.exit(0 if os.environ['GUI_PRESENT'] == '1' else 1)
''')
        self.stub('brew', '''import json, os, sys
from pathlib import Path
p=Path(os.environ['HOME'])/'registered'
a=sys.argv[1:]
with open(os.environ['LOG'], 'a') as f: f.write('brew '+ ' '.join(a)+' SUDO_USER=' + ('set' if 'SUDO_USER' in os.environ else 'unset') + '\\n')
if a == ['services','info','container','--json']: print(json.dumps([{'name':'container','registered':p.exists()}]))
elif a == ['services','start','container']: p.touch()
else: sys.exit(11)
''')
        for gui in (True, False):
            for registered in (False, True):
                for running in (False, True):
                    with self.subTest(gui=gui, registered=registered, running=running):
                        for name, present in [('registered', registered), ('running', running)]:
                            path = self.root / name
                            path.unlink(missing_ok=True)
                            if present: path.touch()
                        self.log.write_text('')
                        env = self.env | {'SUDO_USER': 'invoker', 'GUI_PRESENT': str(int(gui))}
                        result = subprocess.run(['sh', str(script)], env=env, capture_output=True)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        log = self.log.read_text().splitlines()
                        marker = 'unset' if gui else 'set'
                        expected = [f'launchctl print gui/{os.getuid()}',
                                    'container system status --format json',
                                    f'brew services info container --json SUDO_USER={marker}']
                        if not running:
                            expected += ['container system start --disable-kernel-install',
                                         'container system kernel set --recommended --force']
                        if not registered:
                            expected += [f'brew services start container SUDO_USER={marker}',
                                         f'brew services info container --json SUDO_USER={marker}']
                        expected += ['container system status --format json']
                        self.assertEqual(log, expected)

    @unittest.skipUnless(ACTIVATIONS, 'activation declarations supplied by darwin-config')
    def test_activation_calls(self):
        import re
        for entry in json.loads(ACTIVATIONS.read_text()):
            self.log.write_text('')
            # nix-darwin's activate starts with `cd /`, so a step that asks git
            # for the checkout gets no repository, as the real git reports.
            self.stub('git', "import os, sys\nfrom pathlib import Path\nd=Path.cwd()\nwhile not (d/'.git').exists():\n if d==d.parent: sys.exit('fatal: not a git repository (or any of the parent directories): .git')\n d=d.parent\nprint(d)")
            self.stub('sudo', "import os, sys\na=sys.argv[1:]\nwhile a and a[0].startswith('--'): a=a[1:]\nos.execvpe(a[0],a,os.environ)")
            self.stub('macos-xcode', "import json,os,sys\nopen(os.environ['LOG'],'a').write(json.dumps(sys.argv[1:])+'\\n')")
            self.stub('container-setup', "import os\nopen(os.environ['LOG'],'a').write('container-setup\\n')")
            self.stub('launchctl', "import os, sys\na=sys.argv[1:]\nassert a[:2] == ['asuser', '501']\nopen(os.environ['LOG'],'a').write('launchctl asuser 501\\n')\nos.execvpe(a[2], a[2:], os.environ)")
            self.stub('id', "import os, sys\nassert sys.argv[1:] == ['-u', '--', os.environ['EXPECTED_OWNER']]\nprint('501')")
            lines = entry['text'].splitlines()
            blocks = []
            for i,line in enumerate(lines):
                if 'xcodeSource=' in line or '/bin/macos-xcode' in line or '/macos-container.sh' in line:
                    if '/macos-container.sh' in line:
                        blocks.append(line)
                    else:
                        block = [line]
                        j=i+1
                        while j < len(lines):
                            block.append(lines[j])
                            if not lines[j].rstrip().endswith(chr(92)): break
                            j+=1
                        blocks.append('\n'.join(block))
            script='\n'.join(blocks)
            script=re.sub(r'/nix/store/[^ /]+/bin/git', 'git', script)
            script=script.replace('/bin/launchctl', 'launchctl')
            script=script.replace('/usr/bin/sudo', 'sudo')
            script=script.replace('/usr/bin/env', 'env')
            script=re.sub(r'/nix/store/[^ /]+/bin/macos-xcode', 'macos-xcode', script)
            script=re.sub(r'/bin/sh /nix/store/[^ /]+/macos-container.sh', 'container-setup', script)
            script=re.sub(r'PATH="[^"]+"', 'PATH="'+self.env['PATH']+'"', script)
            result=subprocess.run(['bash','-euc',script],env=self.env | {'EXPECTED_OWNER': entry['owner']},capture_output=True,cwd='/')
            self.assertEqual(result.returncode,0,result.stderr)
            records=self.log.read_text().splitlines()
            self.assertEqual(records.count('launchctl asuser 501'),1)
            self.assertEqual(records.count('container-setup'),1)
            self.assertLess(records.index('launchctl asuser 501'), records.index('container-setup'))
            xcodes=[json.loads(line) for line in records if line.startswith('[')]
            self.assertEqual(len(xcodes),0 if entry['bootstrap'] else 1)
            if xcodes:
                args=xcodes[0]
                self.assertEqual(args, ['--source', entry['source'], '--identity', entry['home']+'/.config/nix-config/age/key.txt', '--owner',entry['owner']])



unittest.main()
