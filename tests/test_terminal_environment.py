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
import json, os, pathlib, sys
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
elif name == 'dpkg-query': sys.exit(1 if state.get('private_ghostty') else 0)
elif name == 'zsh': sys.exit(0)
elif name == 'ghostty': print('Ghostty 1.3.1')
elif name == 'chsh':
    state['shell']=args[1]; (root/'state.json').write_text(json.dumps(state))
elif name == 'systemctl':
    if state.get('no_session'): sys.exit(1)
    print(state.get('manager_environment','SHELL='+state.get('manager_shell',state['shell'])))
elif name == 'update-alternatives':
    print('Name: x-terminal-emulator\nValue: '+state.get('alternative','/old/terminal'))
    if not state.get('unregistered_ghostty'):
        print('Alternative: '+shellpath(root/'commands'/'ghostty'))
elif name == 'sudo':
    if args[:3] == ['update-alternatives','--set','x-terminal-emulator']:
        state['alternative']=args[3]; (root/'state.json').write_text(json.dumps(state))
    else: sys.exit(42)
elif name == 'xdg-terminal-exec':
    print(state.get('desktop_id','com.mitchellh.ghostty.desktop'))
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
                     'chsh','systemctl','update-alternatives','sudo','xdg-terminal-exec','swift'):
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
        self.state={'shell':self.shell,'alternative':self.shellpath(self.bin/'ghostty')}
        self.env=os.environ.copy()
        self.env.update(HOME=self.home.as_posix(),USERPROFILE=str(self.home),
                        TERMINAL_TEST_ROOT=str(self.root),SHELL=self.shell,
                        XDG_CONFIG_HOME=self.shellpath(self.home/'xdg'),
                        ZDOTDIR=(self.home/'separate-zsh').as_posix())

    def shellpath(self, p):
        value=p.as_posix()
        return '/'+value[0].lower()+value[2:] if os.name=='nt' else value

    def run_terminal(self, mode='apply', release='26.04', operating_system='linux'):
        (self.root/'state.json').write_text(json.dumps(self.state),encoding='utf-8')
        os_release=self.root/'os-release'
        os_release.write_text('ID=ubuntu\nVERSION_ID='+release+'\n')
        shells=self.root/'shells'
        shells.write_text(self.state.get('allowed',self.shell)+'\n')
        script=self.root/'terminal.sh'
        text=(self.repo/'scripts/terminal-environment.sh').read_text(encoding='utf-8')
        for native, replacement in [("'/etc/os-release'",os_release),("'/etc/shells'",shells),
                                    ("'/snap/bin/ghostty'",self.bin/'ghostty' if self.state.get('snap') else self.root/'no-snap'),
                                    ("'/var/lib/snapd/desktop/applications/ghostty_ghostty.desktop'",self.root/'snap.desktop'),
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

    def calls(self):
        p=self.root/'calls.jsonl'
        return [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []

    def test_apply_and_status_are_idempotent_and_preserve_other_settings(self):
        config=self.home/'xdg/ghostty'
        config.mkdir(parents=True)
        (config/'config').write_text('command = bash\nconfig-file = unwanted\n')
        terminals=self.home/'xdg/ubuntu-xdg-terminals.list'
        terminals.write_text('other.desktop\ncom.mitchellh.ghostty.desktop\n')
        startup=self.home/'.zshrc'; startup.write_text('keep this\n')
        result=self.run_terminal()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertNotIn('command = bash',(config/'config').read_text())
        self.assertNotIn('config-file',(config/'config').read_text())
        for name in ('config', 'config.ghostty'):
            self.assertIn('font-family = Jetendard', (config/name).read_text().splitlines())
        self.assertEqual(terminals.read_text().splitlines(),['com.mitchellh.ghostty.desktop','other.desktop'])
        before={p:p.read_bytes() for p in self.home.rglob('*') if p.is_file()}
        result=self.run_terminal('status')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(before,{p:p.read_bytes() for p in before})
        self.assertFalse(any(name in ('chsh','sudo') for name,args in self.calls()))
        self.assertEqual(startup.read_text(),'keep this\n')
        result=self.run_terminal()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(before,{p:p.read_bytes() for p in before})

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

    def test_native_alternative_is_repaired_and_verified(self):
        self.state['alternative']='/old/terminal'
        result=self.run_terminal(release='24.04')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.state['alternative'],self.shellpath(self.bin/'ghostty'))

    def test_private_or_unregistered_ghostty_is_never_promoted_system_wide(self):
        for condition in ('private_ghostty','unregistered_ghostty'):
            with self.subTest(condition=condition):
                self.state.update(alternative='/old/terminal', **{condition:True})
                result=self.run_terminal(release='24.04')
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('package-registered',result.stderr)
                self.assertFalse(any(name=='sudo' for name,args in self.calls()))
                self.assertEqual(self.state['alternative'],'/old/terminal')
                self.state.pop(condition)

    def test_retained_snap_uses_its_native_desktop_entry(self):
        self.state.update(snap=True,desktop_id='ghostty_ghostty.desktop')
        (self.root/'snap.desktop').write_text('[Desktop Entry]\nType=Application\n')
        result=self.run_terminal()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertNotIn('PENDING',result.stderr)
        self.assertEqual((self.home/'xdg/ubuntu-xdg-terminals.list').read_text(),
                         'ghostty_ghostty.desktop\n')
        self.assertEqual(self.run_terminal('status').returncode,0)

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
        self.assertNotIn('PENDING',result.stderr)
        result=self.run_terminal('status')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

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
        self.assertNotIn('PENDING',result.stderr)
        self.assertEqual(self.state['shell'],selected)
        self.assertFalse(any(name=='chsh' for name,args in self.calls()))

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
        for os_name,arch,release,supported in [('linux','amd64','24.04',True),('linux','arm64','26.04',True),
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
