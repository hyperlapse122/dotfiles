import ast
import json
import os
from pathlib import Path, PureWindowsPath
import shlex
import shutil
import subprocess
import sys
import tempfile
from types import FunctionType, SimpleNamespace
import unittest

from test_native_ca_shell import find_bash


FIXTURE = r'''
import json, os, pathlib, shlex, subprocess, sys
name, *args = sys.argv[1:]
root = pathlib.Path(os.environ['TERMINAL_TEST_ROOT'])
def shellpath(p):
    value=p.as_posix()
    return '/'+value[0].lower()+value[2:] if os.name=='nt' else value
state = json.loads((root/'state.json').read_text())
with (root/'calls.jsonl').open('a') as f: f.write(json.dumps([name, args])+'\n')
if state.get('fail') == name: sys.exit(23)
if name == 'uname': print(state.get('os','Linux') if args == ['-s'] else state.get('machine','x86_64'))
elif name == 'id': print(state.get('uid',1000) if args == ['-u'] else 'fixture')
elif name == 'getent': print('fixture:x:1000:1000:Fixture:'+shellpath(root/'home')+':'+state['shell'])
elif name == 'dscl':
    key=args[-1]; print(key+': '+(state['shell'] if key=='UserShell' else shellpath(root/'home')))
elif name == 'sw_vers': print('26.0')
elif name == 'dpkg': print(state.get('arch','amd64'))
elif name == 'dpkg-query':
    if not state.get('flavor',True): sys.exit(1)
    print('install ok installed')
elif name == 'zsh': sys.exit(0)
elif name == 'ghostty': print('Ghostty 1.3.1')
elif name == 'chsh':
    state['shell']=args[1]; (root/'state.json').write_text(json.dumps(state))
elif name == 'systemctl':
    if state.get('no_session'): sys.exit(1)
    print(state.get('manager_environment','SHELL='+state.get('manager_shell',state['shell'])))
elif name == 'xdg-terminal-exec':
    # Model the dispatcher: the first user preference wins, else the distribution default.
    if args != ['--print-id'] or os.environ.get('XTE_CACHE_ENABLED') != '0': sys.exit(42)
    path=root/'home/xdg/ubuntu-xdg-terminals.list'
    lines=path.read_text().splitlines() if path.exists() else []
    print(lines[0] if lines else 'org.gnome.Ptyxis.desktop')
elif name == 'python3':
    if args[0].endswith('linux-platform.py'):
        import importlib.util
        spec=importlib.util.spec_from_file_location('probe',os.environ['HOST_PROBE'])
        probe=importlib.util.module_from_spec(spec);spec.loader.exec_module(probe)
        def run_probe(args, **kwargs):
            command = shlex.join(['bash', (root/'commands'/args[0]).as_posix(), *args[1:]])
            return subprocess.run([os.environ['FIXTURE_BASH'], '--noprofile', '--norc', '-c', command], **kwargs)
        report=probe.inspect_host(system=state.get('os','Linux'),
            os_release={'ID':state.get('distro','ubuntu'),'VERSION_ID':state.get('release','26.04')},
            run=run_probe)
        print(json.dumps(report));sys.exit(0 if report['supported'] else 1)
    # Native Windows Python cannot open Git Bash /c/... drive paths. Keep
    # shell-facing values POSIX, translating only this native Python boundary.
    if os.name == 'nt':
        # Bash launches these extensionless executables; expose that same
        # lookup capability to native shutil.which without replacing it.
        os.environ['PATHEXT'] = os.environ.get('PATHEXT', '') + ';.'
        # The production POSIX list splits on colons, so omit the drive and
        # resolve from the scratch directory on that same drive.
        os.environ['XDG_DATA_DIRS'] = (root/'system-data').as_posix()[len(root.drive):]
        # Match the native desktop Exec spelling, including the scratch drive's
        # case: production deliberately compares realpath strings exactly.
        args = [(root.drive if arg[1].lower()==root.drive[0].lower() else arg[1]+':')+arg[2:]
                if len(arg)>2 and arg[0]=='/' and
                arg[1].isalpha() and arg[2]=='/' else arg for arg in args]
    sys.exit(subprocess.run([sys.executable, *args]).returncode)
elif name == 'swift':
    if state.get('swift_pending'): sys.exit(2)
    print('Ghostty Unix-executable association is ready.')
'''


class TerminalFixtureWindowsBoundaryTest(unittest.TestCase):
    def run_boundary(self, root, args, environ=None):
        # Execute the actual Windows conversion even on non-Windows hosts.
        branches = [node for node in ast.walk(ast.parse(FIXTURE))
                    if isinstance(node, ast.If) and ast.unparse(node.test) == "os.name == 'nt'"]
        self.assertEqual(len(branches), 1)
        boundary = compile(ast.Module(body=branches[0].body, type_ignores=[]), '<fixture boundary>', 'exec')
        scope = dict(root=root, args=args, os=SimpleNamespace(environ={} if environ is None else environ))
        exec(boundary, scope)
        return scope

    def test_native_arguments_retain_scratch_drive_spelling(self):
        for drive in ('C:', 'c:', 'D:', 'd:'):
            with self.subTest(drive=drive):
                root = PureWindowsPath(drive + "/Users/fixture/terminal 환경 'scratch")
                suffix = root.as_posix()[len(drive):]
                literals = ['-f=${Status}', "space 환경 'path", '', '/', '/usr/bin', '/c',
                            '/1/path', '/cfoo', (root/'commands/ghostty').as_posix()]
                scope = self.run_boundary(root, ['/'+drive[0].lower()+suffix+'/commands/ghostty',
                                                '/'+drive[0].upper()+suffix+'/home', '/z/other', *literals])
                self.assertEqual(scope['args'], [(root/'commands/ghostty').as_posix(),
                                                 (root/'home').as_posix(), 'z:/other', *literals])
                data_dirs = scope['os'].environ['XDG_DATA_DIRS']
                self.assertNotIn(':', data_dirs)
                self.assertEqual((root/data_dirs).as_posix(), (root/'system-data').as_posix())

    def test_native_lookup_finds_the_extensionless_bash_executable(self):
        with tempfile.TemporaryDirectory() as scratch:
            binary = Path(scratch)/'ghostty'
            binary.write_text('#!/bin/sh\nexit 0\n')
            binary.chmod(0o755)
            environ = {'PATHEXT': '.EXE;.CMD'}
            # Run the real Windows which algorithm against a real local file.
            # Only platform selection and the environment separator differ.
            windows_os = SimpleNamespace(**{**vars(os), 'pathsep': ';', 'getenv': environ.get})
            which = FunctionType(shutil.which.__code__,
                                 {**shutil.which.__globals__, 'os': windows_os,
                                  'sys': SimpleNamespace(platform='win32')}, argdefs=shutil.which.__defaults__)
            self.assertIsNone(which(str(binary)))
            self.run_boundary(PureWindowsPath('C:/scratch'), [], environ)
            self.assertEqual(which(str(binary)), str(binary))
            self.assertIn('.EXE;.CMD', environ['PATHEXT'])


@unittest.skipUnless(find_bash(), 'Native Bash or Git Bash required')
class TerminalEnvironmentTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="terminal 환경 '")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.home = self.root/'home'
        self.home.mkdir()
        self.bin = self.root/'commands'
        self.bin.mkdir()
        self.fixture = self.root/'fixture.py'
        self.fixture.write_text(FIXTURE, encoding='utf-8')
        for name in ('uname','id','getent','dscl','sw_vers','dpkg','dpkg-query','zsh','ghostty',
                     'chsh','systemctl','xdg-terminal-exec','python3','swift'):
            p=self.bin/name
            p.write_text('#!/bin/sh\nexport MSYS2_ARG_CONV_EXCL="*"\nexec '+shlex.quote(Path(sys.executable).as_posix())+' '+
                         shlex.quote(self.fixture.as_posix())+' '+shlex.quote(name)+' "$@"\n',encoding='utf-8')
            p.chmod(0o755)
        utilities=('bash','awk','cat','cmp','cp','dirname','grep','mkdir','mktemp','mv','readlink','rm','sed')
        resolved=subprocess.run([find_bash(),'--noprofile','--norc','-c',
                                 'PATH=/usr/bin:/bin; command -v '+' '.join(utilities)],
                                capture_output=True,text=True,check=True)
        for name,target in zip(utilities,resolved.stdout.splitlines(),strict=True):
            p=self.bin/name
            p.write_text('#!/bin/sh\nexec '+shlex.quote(target)+' "$@"\n',encoding='utf-8')
            p.chmod(0o755)
        self.shell=self.shellpath(self.bin/'zsh')
        self.state={'shell':self.shell}
        self.env=os.environ.copy()
        self.env.update(HOME=self.home.as_posix(),USERPROFILE=str(self.home),
                        TERMINAL_TEST_ROOT=str(self.root),SHELL=self.shell,
                        FIXTURE_BASH=find_bash(), HOST_PROBE=str(self.repo/'scripts/linux-platform.py'),
                        XDG_DATA_HOME=str(self.root/'data'),XDG_DATA_DIRS=str(self.root/'system-data'),
                        XDG_CONFIG_HOME=self.shellpath(self.home/'xdg'),
                        ZDOTDIR=(self.home/'separate-zsh').as_posix())

        entries=self.root/'data/applications'
        entries.mkdir(parents=True)
        (entries/'com.mitchellh.ghostty.desktop').write_text(
            '[Desktop Entry]\nType=Application\nExec='+shlex.quote((self.bin/'ghostty').as_posix())+' --new-window\n')

    def shellpath(self, p):
        value=p.as_posix()
        return '/'+value[0].lower()+value[2:] if os.name=='nt' else value

    def run_terminal(self, mode='apply', release='26.04', operating_system='linux'):
        self.state['release']=release
        (self.root/'state.json').write_text(json.dumps(self.state),encoding='utf-8')
        os_release=self.root/'os-release'
        os_release.write_text('ID=ubuntu\nVERSION_ID='+release+'\n')
        shells=self.root/'shells'
        shells.write_text(self.state.get('allowed',self.shell)+'\n')
        script=self.root/'terminal.sh'
        text=(self.repo/'scripts/terminal-environment.sh').read_text(encoding='utf-8')
        for native, replacement in [("'/etc/os-release'",os_release),("'/etc/shells'",shells),
                                    ("'/bin/zsh'",self.bin/'zsh'),("'/usr/bin/zsh'",self.bin/'zsh')]:
            text=text.replace(native,shlex.quote(self.shellpath(replacement)))
        script.write_text(text,encoding='utf-8')
        command='PATH="$(cd "$1" && pwd -P)"; export PATH; shift; exec bash --noprofile --norc "$@"'
        result=subprocess.run([find_bash(),'--noprofile','--norc','-c',command,'fixture',
                               self.bin.as_posix(),script.as_posix(),mode,operating_system,'amd64' if operating_system=='linux' else 'arm64',
                               release,self.home.as_posix(),(self.repo/'scripts/ghostty-default-terminal.swift').as_posix(),
                               (self.repo/'home/.chezmoitemplates/ghostty-config').as_posix()],
                              env=self.env,cwd=self.root,capture_output=True,text=True,encoding='utf-8',timeout=30)
        self.state=json.loads((self.root/'state.json').read_text())
        return result

    def test_host_probe_runs_non_executable_shell_fixtures(self):
        for name in ('dpkg', 'dpkg-query'):
            (self.bin / name).chmod(0o644)
        result = self.run_terminal()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(['dpkg', ['--print-architecture']], self.calls())
        self.assertIn(['dpkg-query', ['-W', '-f=${Status}', 'ubuntu-desktop']], self.calls())

    def calls(self):
        p=self.root/'calls.jsonl'
        return [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []

    def test_inline_python_preserves_arguments_paths_and_failure_status(self):
        (self.root/'state.json').write_text(json.dumps(self.state))
        arguments = ['-f=${Status}', "space 환경 'path", '', self.shellpath(self.bin/'ghostty')]
        command = shlex.join(['bash', (self.bin/'python3').as_posix(), '-', *arguments])
        for status in (0, 23):
            with self.subTest(status=status):
                result = subprocess.run(
                    [find_bash(), '--noprofile', '--norc', '-c', command],
                    input='import json, pathlib, shutil, sys; print(json.dumps(sys.argv[1:])); '
                          'assert pathlib.Path(sys.argv[-1]).is_file(); '
                          'assert shutil.which(sys.argv[-1]) is not None; sys.exit('+str(status)+')',
                    env=self.env, cwd=self.root, capture_output=True, text=True, encoding='utf-8', timeout=30)
                self.assertEqual(result.returncode, status, result.stdout+result.stderr)
                self.assertEqual(json.loads(result.stdout),
                                 [*arguments[:-1], (self.bin/'ghostty').as_posix()])

    def test_system_data_directory_entry_matches_native_executable(self):
        system_data = self.root/'system-data'
        shutil.move(self.root/'data', system_data)
        result = self.run_terminal()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertEqual((self.home/'xdg/ubuntu-xdg-terminals.list').read_text(),
                         'com.mitchellh.ghostty.desktop\n')

    def test_apply_and_status_are_idempotent_and_preserve_other_settings(self):
        config=self.home/'xdg/ghostty'
        config.mkdir(parents=True)
        (config/'config').write_text('command = bash\nconfig-file = unwanted\n')
        terminals=self.home/'xdg/ubuntu-xdg-terminals.list'
        terminals.write_text('org.gnome.Ptyxis.desktop\ncom.mitchellh.ghostty.desktop\norg.gnome.Terminal.desktop\n')
        kde=self.home/'xdg/kdeglobals'
        kde.write_text('[General]\nTerminalApplication=konsole\nTerminalService=org.kde.konsole.desktop\n')
        startup=self.home/'.zshrc'; startup.write_text('keep this\n')
        result=self.run_terminal()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertNotIn('command = bash',(config/'config').read_text())
        self.assertNotIn('config-file',(config/'config').read_text())
        for name in ('config', 'config.ghostty'):
            self.assertIn('font-family = Jetendard', (config/name).read_text().splitlines())
        self.assertEqual(terminals.read_text(),
                         'com.mitchellh.ghostty.desktop\norg.gnome.Ptyxis.desktop\norg.gnome.Terminal.desktop\n')
        self.assertEqual(kde.read_text(),'[General]\nTerminalApplication=konsole\nTerminalService=org.kde.konsole.desktop\n')
        self.assertEqual(sorted(p.name for p in (self.home/'xdg').iterdir()),
                         ['ghostty','kdeglobals','ubuntu-xdg-terminals.list'])
        before={p:(p.read_bytes(),p.stat().st_mtime_ns) for p in self.home.rglob('*') if p.is_file()}
        result=self.run_terminal('status')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertEqual([line for line in result.stderr.splitlines() if 'PENDING' in line],
                         ['Terminal environment PENDING: Native GNOME acceptance remains unverified: check Ctrl+Alt+T, '
                          'the Files terminal action, and a Terminal=true launcher in a fresh desktop session.'])
        self.assertEqual(before,{p:(p.read_bytes(),p.stat().st_mtime_ns) for p in before})
        self.assertFalse(any(name in ('chsh','sudo') for name,args in self.calls()))
        self.assertEqual(startup.read_text(),'keep this\n')
        result=self.run_terminal()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(before,{p:(p.read_bytes(),p.stat().st_mtime_ns) for p in self.home.rglob('*') if p.is_file()})

    def test_apply_creates_the_preference_list_when_absent(self):
        result=self.run_terminal()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual((self.home/'xdg/ubuntu-xdg-terminals.list').read_text(),'com.mitchellh.ghostty.desktop\n')

    def test_status_reports_drift_without_writing_the_preference_list(self):
        config=self.home/'xdg'
        config.mkdir()
        terminals=config/'ubuntu-xdg-terminals.list'
        terminals.write_text('org.gnome.Ptyxis.desktop\ncom.mitchellh.ghostty.desktop\n')
        before=terminals.read_bytes()
        result=self.run_terminal('status')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertIn('dispatcher does not select the installed Ghostty entry',result.stderr)
        self.assertEqual(terminals.read_bytes(),before)
        self.assertEqual([p.name for p in config.iterdir() if p.name!='ghostty'],['ubuntu-xdg-terminals.list'])
        terminals.unlink()
        result=self.run_terminal('status')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertIn('dispatcher does not select the installed Ghostty entry',result.stderr)
        self.assertFalse(terminals.exists())

    def test_shell_change_is_pending_but_apply_allows_following_hooks(self):
        self.state['shell']='/bin/bash'
        self.env['SHELL']='/bin/bash'
        result=self.run_terminal()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('PENDING',result.stderr)
        self.assertEqual(self.state['shell'],self.shell)
        self.assertTrue(any(name=='chsh' for name,args in self.calls()))
        result=self.run_terminal('status')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)

    def test_unregistered_shell_and_failed_chsh_are_errors(self):
        self.state.update(shell='/bin/bash',allowed='/different/zsh')
        result=self.run_terminal()
        self.assertEqual(result.returncode,1)
        self.assertFalse(any(name=='chsh' for name,args in self.calls()))
        self.state.update(allowed=self.shell,fail='chsh')
        result=self.run_terminal()
        self.assertEqual(result.returncode,1)

    def test_rejects_unsupported_hosts_before_personal_writes(self):
        for change,release in [({},'24.04'),({'flavor':False},'26.04'),
                               ({'arch':'arm64'},'26.04'),({'distro':'debian'},'26.04')]:
            with self.subTest(change=change,release=release):
                original=self.state.copy()
                self.state.update(change)
                result=self.run_terminal(release=release)
                self.assertEqual(result.returncode,1,result.stdout+result.stderr)
                self.assertFalse((self.home/'xdg').exists())
                self.state=original

    def test_retained_snap_uses_its_installed_exec_and_desktop_id(self):
        entries=self.root/'data/applications'
        (entries/'com.mitchellh.ghostty.desktop').unlink()
        (entries/'ghostty_ghostty.desktop').write_text(
            '[Desktop Entry]\nType=Application\nExec=env SNAP_TEST=yes '+shlex.quote((self.bin/'ghostty').as_posix())+' -e\n')
        result=self.run_terminal()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual((self.home/'xdg/ubuntu-xdg-terminals.list').read_text(),'ghostty_ghostty.desktop\n')
        self.assertEqual(self.run_terminal('status').returncode,2)

    def test_missing_or_wrong_desktop_entry_fails_without_writing_the_preference_list(self):
        entry=self.root/'data/applications/com.mitchellh.ghostty.desktop'
        for metadata in ('', '[Desktop Entry]\nType=Application\nExec=/bin/false\n',
                         '[Desktop Entry]\nType=Application\nHidden=true\nExec=ghostty\n'):
            entry.write_text(metadata)
            result=self.run_terminal()
            self.assertEqual(result.returncode,1,result.stdout+result.stderr)
            self.assertFalse((self.home/'xdg/ubuntu-xdg-terminals.list').exists())
            self.assertFalse(any(name=='xdg-terminal-exec' for name,args in self.calls()))

    def test_missing_or_failing_dispatcher_is_an_error(self):
        self.state['fail']='xdg-terminal-exec'
        result=self.run_terminal()
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('Cannot inspect the effective desktop terminal',result.stderr)
        self.state.pop('fail')
        (self.bin/'xdg-terminal-exec').unlink()
        result=self.run_terminal('status')
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('xdg-terminal-exec is missing',result.stderr)

    def test_graphical_environment_alone_does_not_prove_native_launch(self):
        self.env.update(XDG_CURRENT_DESKTOP='ubuntu:GNOME',XDG_SESSION_TYPE='wayland')
        self.run_terminal()
        result=self.run_terminal('status')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertIn('Native GNOME acceptance remains unverified',result.stderr)

    def test_stale_manager_environment_and_missing_session_are_pending(self):
        self.run_terminal()
        for state in ({'manager_shell':'/bin/bash'},{'no_session':True}):
            self.state.update(state)
            result=self.run_terminal('status')
            self.assertEqual(result.returncode,2,result.stdout+result.stderr)

    def test_manager_without_shell_uses_the_account_default(self):
        self.state['manager_environment']='PATH=/usr/bin'
        result=self.run_terminal()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('Native GNOME acceptance remains unverified',result.stderr)
        result=self.run_terminal('status')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)

    def test_root_refusal_precedes_configuration_writes(self):
        self.state['uid']=0
        result=self.run_terminal()
        self.assertEqual(result.returncode,1)
        self.assertFalse((self.home/'xdg').exists())
        self.assertFalse(any(name in ('chsh','sudo','swift') for name,args in self.calls()))

    def test_existing_registered_zsh_and_equivalent_session_path_are_retained(self):
        registered=self.root/'registered/zsh'
        registered.parent.mkdir()
        os.link(self.bin/'zsh',registered)
        selected=self.shellpath(registered)
        self.state.update(shell=selected,allowed=selected+'\n'+self.shell)
        result=self.run_terminal()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('Native GNOME acceptance remains unverified',result.stderr)
        self.assertEqual(self.state['shell'],selected)
        self.assertFalse(any(name=='chsh' for name,args in self.calls()))

    def test_mac_status_keeps_native_association_behavior(self):
        self.state.update(os='Darwin',machine='arm64')
        self.assertEqual(self.run_terminal(operating_system='darwin',release='26').returncode,0)
        result=self.run_terminal('status',operating_system='darwin',release='26')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('READY',result.stdout)
        self.assertFalse(any(name in ('python3','xdg-terminal-exec') for name,args in self.calls()))

    def test_mac_native_approval_pending_does_not_fail_apply(self):
        self.state.update(os='Darwin',machine='arm64',swift_pending=True)
        result=self.run_terminal(operating_system='darwin',release='26')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('PENDING',result.stderr)
        self.assertTrue((self.home/'Library/Application Support/com.mitchellh.ghostty/config.ghostty').exists())

    @unittest.skipUnless(shutil.which('chezmoi'),'Real chezmoi required')
    def test_hook_renders_only_supported_targets(self):
        source=self.root/'source'; templates=source/'.chezmoitemplates'; templates.mkdir(parents=True)
        shutil.copy2(self.repo/'home/.chezmoiscripts/run_after_35-terminal-environment.sh.tmpl',templates/'hook')
        config=self.root/'empty.toml';config.write_text('')
        for os_name,arch,release,supported in [('linux','amd64','24.04',False),('linux','arm64','26.04',False),
                                               ('linux','amd64','26.04',True),
                                               ('darwin','arm64','',True),('darwin','amd64','',False),
                                               ('linux','amd64','25.10',False),('windows','amd64','',False)]:
            data={'chezmoi':{'os':os_name,'arch':arch,'osRelease':{'id':'ubuntu','versionID':release},
                             'workingTree':str(self.repo),'destDir':str(self.home)}}
            text='{{ $data := '+json.dumps(json.dumps(data))+' | fromJson }}{{ includeTemplate "hook" $data }}'
            result=subprocess.run(['chezmoi','--source',str(source),'--config',str(config),'execute-template',text],
                                  env=self.env,capture_output=True,text=True,encoding='utf-8',timeout=30)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertEqual(bool(result.stdout.strip()),supported)
            if supported:
                syntax=subprocess.run([find_bash(),'-n'],input=result.stdout,capture_output=True,text=True)
                self.assertEqual(syntax.returncode,0,syntax.stderr)


class NativeWalletBoundaryTest(unittest.TestCase):
    def test_missing_defaultless_and_locked_service_never_store_a_credential(self):
        import importlib.util
        from types import ModuleType, SimpleNamespace
        from unittest.mock import Mock, patch

        keyring = ModuleType('keyring')
        backend = ModuleType('keyring.backend')
        errors = ModuleType('keyring.errors')
        backend.KeyringBackend = object
        errors.KeyringError = type('KeyringError', (Exception,), {})
        errors.PasswordDeleteError = type('PasswordDeleteError', (Exception,), {})
        secretstorage = ModuleType('secretstorage')
        modules = {'keyring': keyring, 'keyring.backend': backend,
                   'keyring.errors': errors, 'secretstorage': secretstorage}
        path = Path(__file__).resolve().parents[1]/'scripts/cli_native.py'
        spec = importlib.util.spec_from_file_location('terminal_wallet_boundary', path)
        native = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, modules):
            spec.loader.exec_module(native)
            for condition in ('missing-service', 'no-default-collection', 'locked'):
                with self.subTest(condition=condition):
                    connection = SimpleNamespace(close=Mock())
                    collection = SimpleNamespace(
                        collection_path='/org/freedesktop/secrets/collection/default',
                        is_locked=Mock(return_value=True), unlock=Mock(),
                        ensure_not_locked=Mock(side_effect=RuntimeError('still locked')),
                        create_item=Mock())
                    secretstorage.dbus_init = Mock(return_value=connection)
                    secretstorage.get_all_collections = Mock(return_value=[])
                    secretstorage.Collection = Mock(return_value=collection)
                    if condition == 'missing-service':
                        secretstorage.dbus_init.side_effect = RuntimeError('no service')
                    if condition == 'no-default-collection':
                        secretstorage.Collection.side_effect = RuntimeError('no default')
                    with patch.object(native.sys, 'platform', 'linux'), patch.object(
                            native.subprocess, 'run', side_effect=AssertionError('unexpected daemon launch')):
                        with self.assertRaisesRegex(errors.KeyringError, '^Native CLI credential store operation failed$'):
                            native.Keyring().set_password('gh:github.com', 'fixture', 'test-value')
                    collection.create_item.assert_not_called()
                    if condition != 'missing-service':
                        connection.close.assert_called_once()
