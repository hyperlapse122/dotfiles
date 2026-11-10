import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_native_ca_shell import find_bash


FIXTURE = r'''
import json, os, pathlib, subprocess, sys
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
    if not state.get('studio',True): sys.exit(1)
    print('install ok installed')
elif name == 'zsh': sys.exit(0)
elif name == 'ghostty': print('Ghostty 1.3.1')
elif name == 'chsh':
    state['shell']=args[1]; (root/'state.json').write_text(json.dumps(state))
elif name == 'systemctl':
    if state.get('no_session'): sys.exit(1)
    print(state.get('manager_environment','SHELL='+state.get('manager_shell',state['shell'])))
elif name in ('kreadconfig6', 'kwriteconfig6'):
    import configparser
    path=root/'home/xdg/kdeglobals'
    parser=configparser.ConfigParser(interpolation=None)
    parser.optionxform=str
    parser.read(path)
    if args[:5] != ['--file','kdeglobals','--group','General','--key']: sys.exit(42)
    key=args[args.index('--key')+1]
    if name=='kreadconfig6': print(parser.get('General',key,fallback=''))
    else:
        if not parser.has_section('General'): parser.add_section('General')
        parser.set('General',key,args[-1])
        with path.open('w') as f: parser.write(f)
elif name == 'python3':
    if args[0].endswith('linux-platform.py'):
        import importlib.util
        spec=importlib.util.spec_from_file_location('probe',os.environ['STUDIO_PROBE'])
        probe=importlib.util.module_from_spec(spec);spec.loader.exec_module(probe)
        def run_probe(args, **kwargs):
            return subprocess.run([os.environ['FIXTURE_BASH'], (root/'commands'/args[0]).as_posix(), *args[1:]], **kwargs)
        report=probe.inspect_host(system=state.get('os','Linux'),
            os_release={'ID':state.get('distro','ubuntu'),'VERSION_ID':state.get('release','26.04')},
            run=run_probe)
        print(json.dumps(report));sys.exit(0 if report['supported'] else 1)
    os.execv(sys.executable,[sys.executable,*args])
elif name == 'swift':
    if state.get('swift_pending'): sys.exit(2)
    print('Ghostty Unix-executable association is ready.')
'''


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
                     'chsh','systemctl','kwriteconfig6','kreadconfig6','python3','swift'):
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
                        FIXTURE_BASH=find_bash(), STUDIO_PROBE=str(self.repo/'scripts/linux-platform.py'),
                        XDG_DATA_HOME=str(self.root/'data'),XDG_DATA_DIRS=str(self.root/'system-data'),
                        XDG_CONFIG_HOME=self.shellpath(self.home/'xdg'),
                        ZDOTDIR=(self.home/'separate-zsh').as_posix())

        entries=self.root/'data/applications'
        entries.mkdir(parents=True)
        (entries/'com.mitchellh.ghostty.desktop').write_text(
            '[Desktop Entry]\nType=Application\nExec='+shlex.quote(self.shellpath(self.bin/'ghostty'))+' --new-window\n')

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
                              env=self.env,capture_output=True,text=True,encoding='utf-8',timeout=30)
        self.state=json.loads((self.root/'state.json').read_text())
        return result

    def test_host_probe_runs_non_executable_shell_fixtures(self):
        for name in ('dpkg', 'dpkg-query'):
            (self.bin / name).chmod(0o644)
        result = self.run_terminal()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(['dpkg', ['--print-architecture']], self.calls())
        self.assertIn(['dpkg-query', ['-W', '-f=${Status}', 'ubuntustudio-desktop']], self.calls())

    def calls(self):
        p=self.root/'calls.jsonl'
        return [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []

    def test_apply_and_status_are_idempotent_and_preserve_other_settings(self):
        config=self.home/'xdg/ghostty'
        config.mkdir(parents=True)
        (config/'config').write_text('command = bash\nconfig-file = unwanted\n')
        kde=self.home/'xdg/kdeglobals'
        kde.write_text('[General]\nColorScheme=BreezeDark\nTerminalApplication=konsole\n[Other]\nUnrelated=keep\n')
        startup=self.home/'.zshrc'; startup.write_text('keep this\n')
        result=self.run_terminal()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertNotIn('command = bash',(config/'config').read_text())
        self.assertNotIn('config-file',(config/'config').read_text())
        for name in ('config', 'config.ghostty'):
            self.assertIn('font-family = Jetendard', (config/name).read_text().splitlines())
        self.assertIn('ColorScheme = BreezeDark',kde.read_text())
        self.assertIn('Unrelated = keep',kde.read_text())
        self.assertIn('TerminalService = com.mitchellh.ghostty.desktop',kde.read_text())
        self.assertIn(' --new-window',kde.read_text())
        self.assertFalse((self.home/'xdg/ubuntu-xdg-terminals.list').exists())
        before={p:p.read_bytes() for p in self.home.rglob('*') if p.is_file()}
        result=self.run_terminal('status')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertEqual(before,{p:p.read_bytes() for p in before})
        self.assertFalse(any(name in ('chsh','sudo') for name,args in self.calls()))
        self.assertEqual(startup.read_text(),'keep this\n')
        result=self.run_terminal()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(before,{p:p.read_bytes() for p in before})

    def test_status_reports_drift_without_writing_kde_settings(self):
        config=self.home/'xdg'
        config.mkdir()
        kde=config/'kdeglobals'
        kde.write_text('[General]\nTerminalApplication=konsole\nTerminalService=org.kde.konsole.desktop\n')
        before=kde.read_bytes()
        result=self.run_terminal('status')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertIn('KDE TerminalApplication',result.stderr)
        self.assertIn('KDE TerminalService',result.stderr)
        self.assertEqual(kde.read_bytes(),before)
        self.assertFalse(any(name=='kwriteconfig6' for name,args in self.calls()))

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
        for change,release in [({},'24.04'),({'studio':False},'26.04'),
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
            '[Desktop Entry]\nType=Application\nExec=env SNAP_TEST=yes '+shlex.quote(self.shellpath(self.bin/'ghostty'))+' -e\n')
        result=self.run_terminal()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        kde=(self.home/'xdg/kdeglobals').read_text()
        self.assertIn('TerminalService = ghostty_ghostty.desktop',kde)
        self.assertIn('TerminalApplication = env SNAP_TEST=yes ',kde)
        self.assertEqual(self.run_terminal('status').returncode,2)

    def test_missing_or_wrong_desktop_entry_fails_without_changing_kde(self):
        entry=self.root/'data/applications/com.mitchellh.ghostty.desktop'
        for metadata in ('', '[Desktop Entry]\nType=Application\nExec=/bin/false\n',
                         '[Desktop Entry]\nType=Application\nHidden=true\nExec=ghostty\n'):
            entry.write_text(metadata)
            result=self.run_terminal()
            self.assertEqual(result.returncode,1,result.stdout+result.stderr)
            self.assertFalse(any(name=='kwriteconfig6' for name,args in self.calls()))

    def test_kde_read_or_write_failure_is_an_error(self):
        for command in ('kreadconfig6','kwriteconfig6'):
            self.state['fail']=command
            result=self.run_terminal()
            self.assertEqual(result.returncode,1,result.stdout+result.stderr)

    def test_graphical_environment_alone_does_not_prove_native_launch(self):
        self.env.update(XDG_CURRENT_DESKTOP='KDE',XDG_SESSION_TYPE='wayland')
        self.run_terminal()
        result=self.run_terminal('status')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertIn('Native Plasma acceptance remains unverified',result.stderr)

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
        self.assertIn('Native Plasma acceptance remains unverified',result.stderr)
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
        self.assertIn('Native Plasma acceptance remains unverified',result.stderr)
        self.assertEqual(self.state['shell'],selected)
        self.assertFalse(any(name=='chsh' for name,args in self.calls()))

    def test_mac_status_keeps_native_association_behavior(self):
        self.state.update(os='Darwin',machine='arm64')
        self.assertEqual(self.run_terminal(operating_system='darwin',release='26').returncode,0)
        result=self.run_terminal('status',operating_system='darwin',release='26')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('READY',result.stdout)
        self.assertFalse(any(name in ('python3','kreadconfig6','kwriteconfig6') for name,args in self.calls()))

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
