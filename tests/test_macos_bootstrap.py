import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest

from test_native_ca_shell import find_bash


FIXTURE = r'''
import json, os, pathlib, sys
# Model macOS command output even when Python runs on Windows.
sys.stdout.reconfigure(newline='\n')
sys.stderr.reconfigure(newline='\n')
name, *args = sys.argv[1:]
root = pathlib.Path(os.environ['MAC_TEST_ROOT'])
state = json.loads((root/'state.json').read_text())
with (root/'calls.jsonl').open('a') as f: f.write(json.dumps([name, args])+'\n')
if state.get('fail') == name: sys.exit(23)
if state.get('fail') == ' '.join([name, *args]): sys.exit(23)
if name == 'uname': print(state.get('os','Darwin') if args == ['-s'] else state.get('arch','arm64'))
elif name == 'sw_vers': print(state.get('version','26.0'))
elif name == 'sysctl': print(state.get('translated','0'))
elif name == 'xcode-select': print('/Library/Developer/CommandLineTools')
elif name == 'xcrun': print('/usr/bin/clang')
elif name == 'id': print(state.get('uid', '501'))
elif name == 'launchctl':
    if args[:1] != ['print']: sys.exit('Only read-only launchctl print is allowed')
    domain = args[1]
    response = state.get('launchd', {}).get(domain, {})
    print(response.get('output', domain + ' = {\n\tservices = {\n\t}\n}'),
          file=sys.stderr if response.get('status', 0) else sys.stdout)
    sys.exit(response.get('status', 0))
elif name == 'brew':
    if args == ['--prefix']: print('/opt/homebrew')
    elif args[:1] == ['--prefix']: print((root/'tools'/args[1]).as_posix())
    elif args[:1] == ['list']:
        sys.exit(0 if args[-1] in state.get('packages',[]) else 1)
    elif args[:1] == ['install']:
        state.setdefault('packages',[]).append(args[-1])
        if args[-1]=='podman':
            import shutil
            dest=root/'tools/podman/bin/podman'; dest.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(root/'podman-template',dest)
        (root/'state.json').write_text(json.dumps(state))
    elif args == ['update']:
        state.setdefault('launchd', {}).update(state.get('launchd_after_update', {}))
        (root/'state.json').write_text(json.dumps(state))
elif name == 'git':
    if args[0] == 'clone':
        target=pathlib.Path(args[-1]); (target/'.git').mkdir(parents=True)
        (target/'mise.toml').write_text(''); (target/'.chezmoi-bootstrap.toml').write_text('')
        (target/'home').mkdir(); (target/'home/.chezmoi.toml.tmpl').write_text('')
    elif args[-2:] == ['--get','remote.origin.url']: print(state.get('origin','https://github.com/hyperlapse122/dotfiles.git'))
elif name == 'mise':
    if 'exec' in args:
        start=args.index('--')+1
        command=args[start:]
        if command[0]=='python': command[0]=sys.executable
        sys.exit(subprocess_run(command))
elif name == 'chezmoi':
    if args[:1] == ['dump-config']: print(json.dumps({'workingTree':state['source']}))
elif name == 'podman':
    if args[:2] == ['machine','list']:
        print(state.get('machines',''),end='')
    elif args[:2] == ['machine','init']:
        state['machines']='podman-machine-default|false|true\n'
    elif args[:2] == ['machine','start']:
        state['machines']=state['machines'].replace('|false|','|true|')
    elif args[:1] == ['info']: print('arm64')
    (root/'state.json').write_text(json.dumps(state))
'''.replace("root = pathlib", "import subprocess\ndef subprocess_run(args): return subprocess.run(args).returncode\nroot = pathlib")


@unittest.skipUnless(find_bash(), 'Native Bash or Git Bash required')
class MacFixture(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix='mac setup 한글 ')
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.bin = self.root/'commands'
        self.bin.mkdir()
        # Expose only these harmless host utilities. System directories can
        # contain a real Podman, even when the developer's PATH is excluded.
        utilities = ('bash', 'awk', 'dirname', 'ls', 'tr', 'wc')
        resolved = subprocess.run(
            [find_bash(), '--noprofile', '--norc', '-c',
             'PATH=/usr/bin:/bin; export PATH; command -v ' + ' '.join(utilities)],
            capture_output=True, text=True, encoding='utf-8', check=True)
        for name, executable in zip(utilities, resolved.stdout.splitlines(), strict=True):
            target = self.bin/name
            target.write_text('#!/bin/sh\nexec ' + shlex.quote(executable) + ' "$@"\n', encoding='utf-8')
            target.chmod(0o755)
        self.home = self.root/'home'
        self.home.mkdir()
        self.source = self.root/'source with spaces'
        (self.source/'.git').mkdir(parents=True)
        (self.source/'home').mkdir()
        (self.source/'home/.chezmoi.toml.tmpl').write_text('')
        (self.source/'mise.toml').write_text('')
        (self.source/'.chezmoi-bootstrap.toml').write_text('')
        self.state = {'source':str(self.source)}
        self.fixture = self.root/'fixture.py'
        self.fixture.write_text(FIXTURE, encoding='utf-8')
        for command in ['uname','sw_vers','sysctl','xcode-select','xcrun','id','launchctl','brew','git','mise']:
            self.wrapper(self.bin/command, command)
        for package, executable in [('chezmoi','chezmoi'),('gnupg','gpg'),('gnupg','gpgconf'),('pinentry-mac','pinentry-mac')]:
            self.wrapper(self.root/'tools'/package/'bin'/executable, executable)
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home), USERPROFILE=str(self.home),
                        MAC_TEST_ROOT=str(self.root), XDG_CONFIG_HOME=str(self.home/'.config'),
                        XDG_CONFIG_DIRS=str(self.root/'system-config'),
                        XDG_CACHE_HOME=str(self.root/'cache'), XDG_DATA_HOME=str(self.root/'data'),
                        XDG_STATE_HOME=str(self.root/'state'))

    def wrapper(self, path, command):
        path.parent.mkdir(parents=True, exist_ok=True)
        def quote(value): return "'"+str(value).replace("'", "'\\''")+"'"
        path.write_text('#!/bin/sh\nexec '+quote(Path(sys.executable).as_posix())+' '+quote(self.fixture.as_posix())+' '+quote(command)+' "$@"\n', encoding='utf-8')
        path.chmod(0o755)

    def run_script(self, name, *args):
        (self.root/'state.json').write_text(json.dumps(self.state), encoding='utf-8')
        script=self.repo/name
        if name=='scripts/macos-apps.sh':
            # Rebind the native bundled install location in the test copy: a
            # developer's real /opt/podman must remain unreachable on Mac too.
            script=self.root/'macos-apps.sh'
            text=(self.repo/name).read_text(encoding='utf-8')
            text=text.replace('/opt/podman/bin/podman',(self.root/'bundled-podman').as_posix())
            text=text.replace('"/Applications/','"'+(self.root/'Applications').as_posix()+'/')
            script.write_text(text,encoding='utf-8')
        # Let Bash normalize the fixture path without exposing host commands.
        command='PATH="$(cd "$1" && pwd -P)"; export PATH; shift; exec bash --noprofile --norc "$@"'
        return subprocess.run([find_bash(),'--noprofile','--norc','-c',command,'fixture',self.bin.as_posix(),script.as_posix(),*map(str,args)],
                              env=self.env,capture_output=True,text=True,encoding='utf-8',timeout=30)

    def calls(self):
        path=self.root/'calls.jsonl'
        return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []


class MacFixtureIsolationTest(MacFixture):
    def test_launchctl_emits_macos_lf_even_with_windows_text_streams(self):
        domain = 'gui/501'
        for status, output in (
            (0, domain + ' = {\n\tservices = {\n\t}\n}'),
            (112, 'Bad request.\nCould not find domain for user gui: 501'),
        ):
            with self.subTest(status=status):
                self.state['launchd'] = {domain: {'status': status, 'output': output}}
                (self.root/'state.json').write_text(json.dumps(self.state), encoding='utf-8')
                # Force Windows newline translation on any test host. Capture
                # bytes so universal-newline decoding cannot hide a mismatch.
                command = (
                    "import runpy, sys; "
                    "sys.stdout.reconfigure(newline='\\r\\n'); "
                    "sys.stderr.reconfigure(newline='\\r\\n'); "
                    "sys.argv = sys.argv[1:]; "
                    "runpy.run_path(sys.argv[0], run_name='__main__')"
                )
                result = subprocess.run(
                    [sys.executable, '-c', command, str(self.fixture), 'launchctl', 'print', domain],
                    env=self.env, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                expected = (output + '\n').encode('utf-8')
                self.assertEqual(result.stdout, b'' if status else expected)
                self.assertEqual(result.stderr, expected if status else b'')

    def test_fixture_cannot_discover_host_commands(self):
        probe = self.root/'probe.sh'
        probe.write_text('''#!/bin/sh
case "$PATH" in *:*) printf '%s\\n' 'Host search directories remain on PATH' >&2; exit 1;; esac
for tool in podman op curl env; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf 'Unexpected host command: %s\\n' "$tool" >&2
        exit 1
    fi
done
for tool in awk dirname ls tr wc; do
    command -v "$tool" >/dev/null 2>&1 || exit 1
done
''', encoding='utf-8')
        result = self.run_script(str(probe))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class MacBootstrapTest(MacFixture):
    def test_rejects_unsupported_host_before_mutation(self):
        for override,diagnostic in [({'os':'Linux'},'Requires macOS'),({'arch':'x86_64'},'native Apple Silicon'),({'version':'15.7'},'macOS 26'),({'version':'25.9'},'macOS 26'),({'translated':'1'},'Rosetta')]:
            with self.subTest(override=override):
                self.state={'source':str(self.source),**override}
                result=self.run_script('bootstrap.sh', self.source)
                self.assertNotEqual(result.returncode,0)
                self.assertIn(diagnostic,result.stderr)
                self.assertFalse(any(name in ('git','mise') for name,args in self.calls()))

    def test_prepares_checkout_without_apply_or_source_registration(self):
        result=self.run_script('bootstrap.sh',self.source)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        mise=[args for name,args in self.calls() if name=='mise']
        self.assertEqual(Path(mise[0][1]).resolve(),(self.source/'mise.toml').resolve())
        self.assertEqual([mise[0][0],*mise[1:]],['trust',['install'],['run','bootstrap']])
        self.assertFalse(any(name=='chezmoi' and ('init' in args or 'apply' in args) for name,args in self.calls()))
        self.assertFalse(any(name in ('launchctl', 'container', 'podman') for name, args in self.calls()))
        self.assertTrue(all(args[:1] == ['--prefix'] for name, args in self.calls() if name == 'brew'))

    def test_conflicting_origin_is_not_prepared(self):
        self.state['origin']='https://example.invalid/other.git'
        result=self.run_script('bootstrap.sh',self.source)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(name=='mise' for name,args in self.calls()))

    def test_missing_checkout_is_cloned_before_preparation(self):
        destination=self.root/'new checkout'
        result=self.run_script('bootstrap.sh',destination)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertTrue((destination/'.git').is_dir())
        names=[name for name,args in self.calls()]
        self.assertLess(names.index('git'),names.index('mise'))

    def test_failed_preparation_does_not_claim_success(self):
        self.state['fail']='mise'
        result=self.run_script('bootstrap.sh',self.source)
        self.assertEqual(result.returncode,23,result.stdout+result.stderr)
        self.assertNotIn('Prepared:',result.stdout)

    def test_registration_rejects_unsupported_version_before_mutation(self):
        self.state['version'] = '25.9'
        result = self.run_script('configure-chezmoi.sh', self.source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('macOS 26 or later', result.stderr)
        self.assertFalse(any(name in ('git', 'chezmoi', 'brew') for name, args in self.calls()))

    def test_registration_rejects_linked_worktree(self):
        (self.source/'.git').rmdir()
        (self.source/'.git').write_text('gitdir: elsewhere')
        result=self.run_script('configure-chezmoi.sh',self.source)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(name=='chezmoi' and 'init' in args for name,args in self.calls()))

    def test_registration_keeps_conflicting_config_unchanged(self):
        config=self.home/'.config/chezmoi/chezmoi.toml'
        config.parent.mkdir(parents=True)
        original='sourceDir = "/another/source"\n[data]\nunrelated = "retained"\n'
        config.write_text(original)
        result=self.run_script('configure-chezmoi.sh',self.source)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('another source',result.stderr)
        self.assertEqual(config.read_text(),original)
        self.assertFalse(any(name=='chezmoi' and 'init' in args for name,args in self.calls()))

    @unittest.skipIf(os.name == 'nt', 'Native POSIX subprocess executable semantics; conflict checks still run on Windows')
    def test_registration_initializes_without_apply(self):
        result=self.run_script('configure-chezmoi.sh',self.source)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        calls=[args for name,args in self.calls() if name=='chezmoi']
        self.assertEqual(len(calls),1)
        self.assertEqual(calls[0][-1],'init')
        self.assertNotIn('apply',calls[0])

    def test_registration_rejects_other_config_formats(self):
        config=self.home/'.config/chezmoi/chezmoi.yaml'
        config.parent.mkdir(parents=True)
        config.write_text('sourceDir: /another/source\n')
        result=self.run_script('configure-chezmoi.sh',self.source)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('non-TOML',result.stderr)
        self.assertEqual(config.read_text(),'sourceDir: /another/source\n')

    @unittest.skipUnless(os.name != 'nt' and shutil.which('chezmoi'), 'Real POSIX chezmoi required')
    def test_native_registration_preserves_toml_without_applying(self):
        (self.source/'.chezmoiroot').write_text('home\n')
        shutil.copy2(self.repo/'home/.chezmoi.toml.tmpl',self.source/'home/.chezmoi.toml.tmpl')
        for relative in ['.chezmoitemplates/gpg-settings','.chezmoidata/gpg.yaml']:
            target=self.source/'home'/relative
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(self.repo/'home'/relative,target)
        shutil.copy2(shutil.which('chezmoi'),self.root/'tools/chezmoi/bin/chezmoi')
        config=self.home/'.config/chezmoi/chezmoi.toml'
        config.parent.mkdir(parents=True)
        config.write_text('sourceDir = '+json.dumps(str(self.source))+'\n[data]\nunrelated = "retained"\n')
        (self.source/'home/dot_never_applied').write_text('only explicit apply writes this')
        result=self.run_script('configure-chezmoi.sh',self.source)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        data=tomllib.loads(config.read_text())
        self.assertEqual(data['data']['unrelated'],'retained')
        self.assertEqual(Path(data['workingTree']).resolve(),self.source)
        self.assertFalse((self.home/'.never_applied').exists())
