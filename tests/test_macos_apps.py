import json
import shutil
import subprocess
import unittest

from test_macos_bootstrap import MacFixture
from test_native_ca_shell import find_bash


class MacAppsTest(MacFixture):
    def setUp(self):
        super().setUp()
        self.wrapper(self.root/'podman-template','podman')

    def test_unsupported_macos_stops_before_application_changes(self):
        self.state['version'] = '14.7'
        result = self.run_script('scripts/macos-apps.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('macOS 15', result.stderr)
        self.assertFalse(any(name in ('brew', 'podman') for name, args in self.calls()))

    def test_fresh_application_installs_once_and_starts_machine(self):
        result=self.run_script('scripts/macos-apps.sh','cask:google-chrome','cask:1password-cli')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        calls=self.calls()
        self.assertIn(['brew',['install','--formula','podman']],calls)
        self.assertIn(['brew',['install','--cask','1password-cli']],calls)
        self.assertIn(['podman',['machine','init']],calls)
        self.assertIn(['podman',['machine','start']],calls)
        self.state=json.loads((self.root/'state.json').read_text())
        before=len(calls)
        result=self.run_script('scripts/macos-apps.sh','cask:google-chrome','cask:1password-cli')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        repeated=self.calls()[before:]
        self.assertFalse(any(name=='brew' and args[0]=='install' for name,args in repeated))
        self.assertFalse(any(name=='podman' and args[:2] in (['machine','init'],['machine','start']) for name,args in repeated))

    def test_external_engine_and_existing_machine_are_reused(self):
        self.wrapper(self.bin/'podman','podman')
        self.state['machines']='personal|false|true\n'
        result=self.run_script('scripts/macos-apps.sh')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        calls=self.calls()
        self.assertNotIn(['brew',['install','--formula','podman']],calls)
        self.assertIn(['podman',['machine','start','personal']],calls)
        self.assertFalse(any(name=='podman' and ('rm' in args or 'reset' in args or 'init' in args) for name,args in calls))

    def test_command_failure_stops_application(self):
        self.state['fail']='brew'
        result=self.run_script('scripts/macos-apps.sh','cask:google-chrome')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(name=='podman' for name,args in self.calls()))

    def test_ambiguous_stopped_machines_are_not_modified(self):
        self.wrapper(self.bin/'podman','podman')
        self.state['machines']='one|false|false\ntwo|false|false\n'
        result=self.run_script('scripts/macos-apps.sh')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Multiple stopped',result.stderr)
        self.assertFalse(any(name=='podman' and args[:2] in (['machine','init'],['machine','start']) for name,args in self.calls()))

    def test_bundled_engine_never_reaches_native_installation(self):
        self.wrapper(self.root/'bundled-podman','podman')
        self.state['machines']='personal|true|true\n'
        result=self.run_script('scripts/macos-apps.sh')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse(any(name=='brew' and args[0]=='install' for name,args in self.calls()))

    def test_mixed_engine_ownership_fails_without_machine_changes(self):
        self.wrapper(self.root/'bundled-podman','podman')
        self.state['packages']=['podman']
        result=self.run_script('scripts/macos-apps.sh')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Both bundled and Homebrew',result.stderr)
        self.assertFalse(any(name=='podman' for name,args in self.calls()))

    @unittest.skipUnless(shutil.which('chezmoi'), 'Real chezmoi required')
    def test_native_apply_hook_has_platform_guard_and_valid_shell(self):
        templates=self.source/'.chezmoitemplates'
        templates.mkdir()
        hook=self.repo/'home/.chezmoiscripts/run_before_15-install-macos-apps.sh.tmpl'
        shutil.copy2(hook,templates/'app-hook')
        config=self.root/'empty.toml'
        config.write_text('')
        for operating_system,architecture in [('darwin','arm64'),('darwin','amd64'),('windows','amd64'),('linux','arm64')]:
            data={'chezmoi':{'os':operating_system,'arch':architecture,'workingTree':str(self.repo)},
                  'macos':{'formulae':[],'casks':['1password-cli']}}
            template='{{ $data := '+json.dumps(json.dumps(data))+' | fromJson }}{{ includeTemplate "app-hook" $data }}'
            result=subprocess.run(['chezmoi','--source',str(self.source),'--config',str(config),'execute-template',template],
                                  env=self.env,capture_output=True,text=True,encoding='utf-8',timeout=30)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            if operating_system=='darwin' and architecture=='arm64':
                self.assertIn('cask:1password-cli',result.stdout)
                syntax=subprocess.run([find_bash(),'-n'],input=result.stdout,capture_output=True,text=True)
                self.assertEqual(syntax.returncode,0,syntax.stderr)
            else:
                self.assertEqual(result.stdout.strip(),'')
